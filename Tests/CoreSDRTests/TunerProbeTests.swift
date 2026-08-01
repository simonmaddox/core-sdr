import Testing
@testable import CoreSDR

/// `RTLSDRDevice.open()`'s tuner chip-ID probe: an R820T2 answering 0x69 at
/// I2C 0x34 proceeds; an R828D answering only at 0x74 (RTL-SDR Blog V4) or
/// silence at both addresses throws `SDRError.unsupportedTuner` — the honest
/// "this dongle isn't supported yet" the app shows instead of a cryptic USB
/// failure. The mock's un-stubbed reads return zero-fill, which the probe
/// treats as "nothing there", so absence needs no explicit stubbing.

private let i2cReadIndex = UInt16(RTLBlock.i2c.rawValue) << 8

@Test func openProceedsWhenR820T2AnswersBitReversed() async throws {
    let m = MockUSBTransport()
    m.stubRead(value: R820T2.i2cAddress, index: i2cReadIndex, returns: [0x96])  // bitrev(0x69)
    let dev = RTLSDRDevice(transport: m)
    try await dev.open()
}

@Test func openProceedsWhenR820T2AnswersRaw() async throws {
    // The reference driver's addressed probe compares the raw byte; accept
    // that framing too so the check can't false-negative a real R820T2.
    let m = MockUSBTransport()
    m.stubRead(value: R820T2.i2cAddress, index: i2cReadIndex, returns: [0x69])
    let dev = RTLSDRDevice(transport: m)
    try await dev.open()
}

@Test func openNamesTheR828DWhenOnlyItAnswers() async throws {
    let m = MockUSBTransport()
    m.stubRead(value: R820T2.r828dI2CAddress, index: i2cReadIndex, returns: [0x96])
    let dev = RTLSDRDevice(transport: m)
    do {
        try await dev.open()
        Issue.record("open() should have thrown for an R828D tuner")
    } catch let SDRError.unsupportedTuner(detected) {
        #expect(detected == "R828D")
    }
}

@Test func openReportsUnknownTunerWhenNothingAnswers() async throws {
    let m = MockUSBTransport()  // both probe reads fall through to zero-fill
    let dev = RTLSDRDevice(transport: m)
    do {
        try await dev.open()
        Issue.record("open() should have thrown with no recognisable tuner")
    } catch let SDRError.unsupportedTuner(detected) {
        #expect(detected == nil)
    }
}

@Test func failedProbeStillDisablesTheI2CRepeater() async throws {
    // The repeater bracket must close on the throwing path too, or the demod
    // is left proxying its I2C bus. Repeater writes are demod page 1 reg 0x01:
    // value (0x01 << 8) | 0x20, index 0x10 | 1 — data [0x18] on, [0x10] off.
    let m = MockUSBTransport()
    let dev = RTLSDRDevice(transport: m)
    _ = try? await dev.open()
    let repeaterWrites = m.controlWrites.filter {
        $0.request.value == 0x0120 && $0.request.index == 0x11
    }
    #expect(repeaterWrites.last?.data.first == 0x10)
}

@Test func probeHappensBeforeTunerRegisterWrites() async throws {
    // Refuse-before-programming: no IICB tuner *register* write (the 0x0610
    // write-index) may precede the probe's own register-pointer write.
    let m = MockUSBTransport()
    m.stubR820T2Present()
    let dev = RTLSDRDevice(transport: m)
    try await dev.open()
    let probeIndex = m.controlWrites.firstIndex {
        $0.request.index == 0x0610 && $0.request.value == R820T2.i2cAddress && $0.data == [0x00]
    }
    let initIndex = m.controlWrites.firstIndex {
        $0.request.index == 0x0610 && $0.data.count > 1
    }
    #expect(probeIndex != nil && initIndex != nil)
    if let probeIndex, let initIndex {
        #expect(probeIndex < initIndex)
    }
}
