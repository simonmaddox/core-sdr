import Foundation
import Testing
@testable import CoreSDR

/// Hardware-gated regression test for the Stop→restart use-after-free in the
/// IOUSBLib bulk stream: a late aborted `ReadPipeAsync` completion firing on
/// the `bulkIn` run-loop thread after the `BulkReadContext` (and its buffers)
/// had already been freed — `EXC_BAD_ACCESS` in `BulkReadContext.handle`. The
/// fix drains all outstanding reads before `cleanup()` frees anything.
///
/// Rapidly cycles `samples()`/`stop()` so an old stream's teardown races a new
/// start — the exact pattern that crashed. Opt in with a dongle attached:
/// ```
/// CORESDR_HW_TEST=1 swift test --filter streamStopRestartDoesNotCrash
/// ```
@Test(.enabled(if: ProcessInfo.processInfo.environment["CORESDR_HW_TEST"] == "1"))
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
        // A tiny gap so the old ring thread is mid-teardown when the next
        // samples() starts — the window the crash needed.
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
    // Reaching here without an EXC_BAD_ACCESS is the assertion.
    #expect(Bool(true))
}
