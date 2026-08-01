import Testing
@testable import CoreSDR

@Test func openInitializesBasebandThenTuner() async throws {
    let m = MockUSBTransport()
    m.stubR820T2Present()
    let dev = RTLSDRDevice(transport: m)
    try await dev.open()
    // baseband USB_SYSCTL write happens before any IICB tuner write
    let idxSysctl = m.controlWrites.firstIndex { $0.request.value == 0x2000 }!
    let idxTuner = m.controlWrites.firstIndex { $0.request.index == 0x0610 }!
    #expect(idxSysctl < idxTuner)
}
@Test func tuneOutOfRangeThrows() async throws {
    let dev = RTLSDRDevice(transport: MockUSBTransport())
    await #expect(throws: SDRError.self) { try await dev.tune(to: .mhz(3000)) }
}
