import Foundation
import Testing
@testable import CoreSDR

/// Hardware-gated regression test for the Stop→restart failures in the IOUSBLib
/// bulk stream:
///   1. the use-after-free — a late aborted `ReadPipeAsync` completion firing on
///      the `bulkIn` run-loop thread after the `BulkReadContext` (and its
///      buffers) had been freed (`EXC_BAD_ACCESS` in `BulkReadContext.handle`);
///      the drain-before-cleanup fix addresses it.
///   2. the restart race — the old ring's `AbortPipe` aborting the *new* ring's
///      reads on the shared pipe, so the restarted stream yields nothing
///      forever; the deterministic start-ordering fix addresses it.
///
/// Rapidly cycles `samples()`/`stop()` with zero grace between teardown and the
/// next start, so an old ring's teardown maximally overlaps a new start — the
/// exact pattern that crashed and/or silently stalled. Each restarted stream is
/// asserted to actually yield, which would fail on the restart race. Opt in with
/// a dongle attached:
/// ```
/// CORESDR_HW_TEST=1 swift test --filter streamStopRestartDoesNotCrash
/// ```
@Test(
    .enabled(if: ProcessInfo.processInfo.environment["CORESDR_HW_TEST"] == "1"),
    .timeLimit(.minutes(1))   // a restart-race stall must fail, not hang the suite
)
func streamStopRestartDoesNotCrash() async throws {
    let dev = try await SDRDevice.default
    try await dev.tune(to: .mhz(100.0))
    try await dev.setSampleRate(.rate2_4M)
    try await dev.setGain(.automatic)

    for _ in 0..<60 {
        var count = 0
        for try await block in await dev.samples() {
            _ = block
            count += 1
            if count >= 2 { break }   // stop early → onTermination → teardown/abort
        }
        await dev.stop()
        // No grace period: the next samples() starts while the old ring thread is
        // mid-teardown — the window both the crash and the restart race needed.
        // Each iteration's `count` reaching 2 above proves the restarted stream
        // actually yielded (the restart race would stall it at zero forever, and
        // the loop's implicit hang/timeout would surface it).
        #expect(count == 2)
    }
    // Reaching here without an EXC_BAD_ACCESS, and with every restart having
    // yielded, is the assertion.
    #expect(Bool(true))
}
