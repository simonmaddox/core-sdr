import Foundation
import Testing
@testable import CoreSDR

/// Hardware-gated live-capture integration test.
///
/// This test talks to a real, physically-attached RTL-SDR dongle over USB
/// and requires an antenna tuned near a live broadcast station to pass. It
/// is disabled by default (both locally and in CI) and only runs when the
/// operator explicitly opts in via `CORESDR_HW_TEST=1`, since it cannot
/// pass — and shouldn't even attempt — without real hardware present.
///
/// Opt-in run:
/// ```
/// CORESDR_HW_TEST=1 CORESDR_HW_FREQ_MHZ=104.9 swift test --filter HardwareTests
/// ```
@Test(.enabled(if: ProcessInfo.processInfo.environment["CORESDR_HW_TEST"] == "1"))
func liveCaptureHasSignal() async throws {
    // Bulk-transfer size `SDRDevice.samples()` uses per `IQBlock.raw`
    // (documented on `SDRDevice.samples()`: "16384-byte transfers").
    let expectedTransferSize = 16384

    // Mean complex magnitude, sqrt(I^2 + Q^2) over normalized() samples in
    // [-1, 1], that a real broadcast station reliably clears with AGC. In
    // manual live testing: on-station ~0.2, empty-band noise floor ~0.06.
    // 0.1 sits safely between the two so the assertion stays meaningful in
    // both directions (fails on noise, passes on signal) without being
    // flaky against normal AGC/signal variance.
    let magnitudeThreshold: Float = 0.1

    let dev = try await SDRDevice.default

    let mhzString = ProcessInfo.processInfo.environment["CORESDR_HW_FREQ_MHZ"] ?? "104.9"
    let mhz = try #require(Double(mhzString))
    try await dev.tune(to: .mhz(mhz))
    try await dev.setSampleRate(.rate2_4M)
    try await dev.setGain(.automatic)

    var blocks: [IQBlock] = []
    for try await block in await dev.samples() {
        blocks.append(block)
        if blocks.count == 10 { break }
    }
    await dev.stop()

    #expect(blocks.count >= 10)

    var magnitudeSum: Double = 0
    var pairCount = 0
    for block in blocks {
        #expect(!block.raw.isEmpty)
        #expect(block.raw.count == expectedTransferSize)

        let samples = block.normalized()
        var index = 0
        while index + 1 < samples.count {
            let i = samples[index]
            let q = samples[index + 1]
            magnitudeSum += Double((i * i + q * q).squareRoot())
            pairCount += 1
            index += 2
        }
    }

    let meanMagnitude = pairCount > 0 ? Float(magnitudeSum / Double(pairCount)) : 0
    #expect(meanMagnitude > magnitudeThreshold)
}
