import Testing
@testable import CoreSDR

@Test func nearestGainStepSnapsToTable() {
    let caps = SDRCapabilities(
        frequencyRange: Frequency.mhz(24)...Frequency.mhz(1766),
        supportedSampleRates: [.rate2_4M],
        gainSteps: [0.0, 0.9, 1.4, 2.7]
    )
    #expect(caps.nearestGainStep(to: 1.0) == 0.9)
    #expect(caps.nearestGainStep(to: 2.6) == 2.7)
}
