import Testing
@testable import CoreSDR

@Test func resamplerRatioForKnownRate() {
    // xtal=28.8e6, rate=2.4e6: (28_800_000 * 4_194_304) / 2_400_000 = 50_331_648 = 0x03000000
    #expect(RTL2832U.resamplerRatio(sampleRate: 2_400_000) == 0x0300_0000)
}
@Test func setSampleRateWrites9fAndA1ThenResets() async throws {
    let m = MockUSBTransport()
    let rtl = RTL2832U(transport: m)
    try await rtl.setSampleRate(.rate2_4M)
    let w = m.controlWrites
    // ratio 0x03000000 → high 0x0300 to 0x9f, low 0x0000 to 0xa1
    #expect(w.contains { $0.request.value == 0x9f20 && $0.data == [0x03, 0x00] })
    #expect(w.contains { $0.request.value == 0xa120 && $0.data == [0x00, 0x00] })
    // soft reset pair at the end
    #expect(w.suffix(2).map(\.data) == [[0x14], [0x10]])
}
@Test func invalidRateThrows() async throws {
    let m = MockUSBTransport()
    let rtl = RTL2832U(transport: m)
    await #expect(throws: SDRError.self) { try await rtl.setSampleRate(SampleRate(hertz: 600_000)) }
}
