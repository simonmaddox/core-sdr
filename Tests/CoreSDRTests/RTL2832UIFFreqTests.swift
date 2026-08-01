import Testing
@testable import CoreSDR

@Test func setIFFrequencyEmitsThreeDemodWrites() async throws {
    let m = MockUSBTransport()
    m.stubR820T2Present()
    let rtl = RTL2832U(transport: m)
    try await rtl.setIFFrequency(3_570_000)

    // Three consecutive demod writes to page 1 (index 0x11) at addr 0x19/0x1a/0x1b.
    // For freqHz=3_570_000, xtal=28_800_000: ifFreq = -519918 (0xFFF81112) →
    // page1 0x19 = 0x38, 0x1a = 0x11, 0x1b = 0x12.
    let ifWrites = m.controlWrites.filter {
        $0.request.index == 0x0011 &&
        ($0.request.value == 0x1920 || $0.request.value == 0x1a20 || $0.request.value == 0x1b20)
    }
    #expect(ifWrites.count == 3)
    #expect(ifWrites[0].request.value == 0x1920 && ifWrites[0].data == [0x38])
    #expect(ifWrites[1].request.value == 0x1a20 && ifWrites[1].data == [0x11])
    #expect(ifWrites[2].request.value == 0x1b20 && ifWrites[2].data == [0x12])
}

@Test func configureForR820T2EmitsFourWritesInOrder() async throws {
    let m = MockUSBTransport()
    m.stubR820T2Present()
    let rtl = RTL2832U(transport: m)
    try await rtl.configureForR820T2()

    // Collect just the config writes (block writes, ignoring demod dummy reads).
    let w = m.controlWrites
    // p1 0xb1=0x1a → value 0xb120, index 0x11
    let idxDisableZeroIF = w.firstIndex { $0.request.value == 0xb120 && $0.request.index == 0x0011 && $0.data == [0x1a] }
    // p0 0x08=0x4d → value 0x0820, index 0x10
    let idxAdcI = w.firstIndex { $0.request.value == 0x0820 && $0.request.index == 0x0010 && $0.data == [0x4d] }
    // IF freq trio (page1 0x19)
    let idxIF = w.firstIndex { $0.request.value == 0x1920 && $0.request.index == 0x0011 && $0.data == [0x38] }
    // p1 0x15=0x01 → value 0x1520, index 0x11
    let idxInvert = w.firstIndex { $0.request.value == 0x1520 && $0.request.index == 0x0011 && $0.data == [0x01] }

    #expect(idxDisableZeroIF != nil)
    #expect(idxAdcI != nil)
    #expect(idxIF != nil)
    #expect(idxInvert != nil)
    #expect(idxDisableZeroIF! < idxAdcI!)
    #expect(idxAdcI! < idxIF!)
    #expect(idxIF! < idxInvert!)
}

@Test func openConfiguresR820T2AfterBasebandAndTunerInit() async throws {
    let m = MockUSBTransport()
    m.stubR820T2Present()
    let dev = RTLSDRDevice(transport: m)
    try await dev.open()
    let w = m.controlWrites

    // Baseband framing (USB_SYSCTL) and first tuner I2C write (index 0x0610).
    let idxSysctl = w.firstIndex { $0.request.value == 0x2000 }!
    let idxTuner = w.firstIndex { $0.request.index == 0x0610 }!

    // The four R820T2 demod-config writes.
    let idxDisableZeroIF = w.firstIndex { $0.request.value == 0xb120 && $0.request.index == 0x0011 && $0.data == [0x1a] }!
    let idxAdcI = w.firstIndex { $0.request.value == 0x0820 && $0.request.index == 0x0010 && $0.data == [0x4d] }!
    let idxIF = w.firstIndex { $0.request.value == 0x1920 && $0.request.index == 0x0011 && $0.data == [0x38] }!
    let idxInvert = w.firstIndex { $0.request.value == 0x1520 && $0.request.index == 0x0011 && $0.data == [0x01] }!

    // Ordering: baseband → tuner init → R820T2 demod config, in order.
    #expect(idxSysctl < idxTuner)
    #expect(idxTuner < idxDisableZeroIF)
    #expect(idxDisableZeroIF < idxAdcI)
    #expect(idxAdcI < idxIF)
    #expect(idxIF < idxInvert)
}
