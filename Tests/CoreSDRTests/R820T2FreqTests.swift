import Testing
import Foundation
@testable import CoreSDR

@Test func setFrequencyMatchesGoldenVectors() async throws {
    let golden = try GoldenVectors.load()
    #expect(golden.setFreq.count == 5)
    for vector in golden.setFreq {
        let m = MockUSBTransport()
        m.stubTunerPLLLocked()
        let r820 = R820T2(rtl: RTL2832U(transport: m))
        try await r820.setFrequency(vector.hz)
        #expect(m.tunerRegisterWrites() == vector.writes, "freq \(vector.hz) Hz")
    }
}

/// A high-band tune (LO >= 885 MHz) puts the VCO-band search at
/// `mix_div == 2`, so `div_num == 0`. A live `vco_fine_tune == 3` then nudges
/// `div_num` to -1, which previously trapped in `UInt8(divNum) << 5`. The clamp
/// saturates it to 0, so bits [7:5] of the div_num write are 0 and the
/// preserved low bits (0x04) stand — no trap.
@Test func setFrequencyClampsNegativeDivNumAtHighBandVcoFineTune3() async throws {
    let m = MockUSBTransport()
    m.stubTunerPLLLocked(vcoFineTune: 3)
    let r820 = R820T2(rtl: RTL2832U(transport: m))
    try await r820.setFrequency(900_000_000)
    // The final reg 0x10 write in the sequence is the div_num write.
    let reg10Writes = m.tunerRegisterWrites().filter { $0.reg == 0x10 }
    #expect(reg10Writes.last?.value == 0x04)
}

/// C2 companion: the same high-band tune with `vco_fine_tune == 1` (< ref 2)
/// nudges `div_num` from 0 up to 1, exercising the previously-untested upward
/// branch. Bits [7:5] become 0x20, over the preserved low bits 0x04.
@Test func setFrequencyNudgesDivNumUpAtHighBandVcoFineTune1() async throws {
    let m = MockUSBTransport()
    m.stubTunerPLLLocked(vcoFineTune: 1)
    let r820 = R820T2(rtl: RTL2832U(transport: m))
    try await r820.setFrequency(900_000_000)
    let reg10Writes = m.tunerRegisterWrites().filter { $0.reg == 0x10 }
    #expect(reg10Writes.last?.value == 0x24)
}

/// A truncated tuner status read (2 bytes for the 5-byte `vco_fine_tune`
/// read) must throw rather than trap indexing `statusData[4]`.
@Test func setFrequencyThrowsOnShortTunerStatusRead() async throws {
    let m = MockUSBTransport()
    m.stubRead(value: 0x34, index: 0x0600, returns: [0x00, 0x00])
    let r820 = R820T2(rtl: RTL2832U(transport: m))
    await #expect(throws: SDRError.self) {
        try await r820.setFrequency(100_000_000)
    }
}

/// When the PLL fails to lock, `tuningOutOfRange` must report the user's
/// requested RF frequency, not the internal LO (requested + 3.57 MHz IF). Both
/// PLL-lock reads report unlocked, so setPLL exhausts its retry and throws.
@Test func tuningOutOfRangeReportsRequestedFrequencyNotLO() async throws {
    let m = MockUSBTransport()
    m.stubRead(value: 0x34, index: 0x0600, returns: [0x00, 0x00, 0x00, 0x00, R820T2.bitReverse(0x20)]) // 5-byte vco_fine_tune read
    m.stubRead(value: 0x34, index: 0x0600, returns: [0x00, 0x00, 0x00]) // 3-byte: unlocked
    m.stubRead(value: 0x34, index: 0x0600, returns: [0x00, 0x00, 0x00]) // 3-byte: unlocked (after current bump)
    let r820 = R820T2(rtl: RTL2832U(transport: m))
    do {
        try await r820.setFrequency(100_000_000)
        Issue.record("expected setFrequency to throw tuningOutOfRange")
    } catch let SDRError.tuningOutOfRange(freq) {
        #expect(freq == Frequency(hertz: 100_000_000))
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

/// The register shadow persists across tunes (like the reference's
/// `priv->regs`) instead of resetting to `postInitShadow()` each call. After a
/// first tune to 868 MHz (div_num 1), the two reg 0x10 writes preceding the
/// div_num write on a second tune to 100 MHz carry the persisted div_num-1
/// state (low state 0x24 -> 36) rather than the post-init default (0x84 -> 132).
/// The final div_num write still lands correctly on 132 (div_num 4). Against
/// the old per-tune reset those two writes would both be 132.
@Test func retunePersistsRegisterShadowAcrossTunes() async throws {
    let m = MockUSBTransport()
    m.stubTunerPLLLocked() // first tune (868 MHz)
    m.stubTunerPLLLocked() // second tune (100 MHz)
    let r820 = R820T2(rtl: RTL2832U(transport: m))

    try await r820.setFrequency(868_000_000)
    let afterFirstTune = m.tunerRegisterWrites().count
    try await r820.setFrequency(100_000_000)
    let secondTune = Array(m.tunerRegisterWrites().suffix(from: afterFirstTune))

    let expected: [TunerWrite] = [
        TunerWrite(reg: 23, value: 48),
        TunerWrite(reg: 26, value: 42),
        TunerWrite(reg: 27, value: 52),
        TunerWrite(reg: 16, value: 36),   // set_mux cap write: RMW vs persisted 0x24
        TunerWrite(reg: 16, value: 36),   // refdiv2 write: RMW vs persisted 0x24
        TunerWrite(reg: 26, value: 34),
        TunerWrite(reg: 16, value: 132),  // div_num 4 write -> 0x84
        TunerWrite(reg: 20, value: 11),
        TunerWrite(reg: 18, value: 128),
        TunerWrite(reg: 22, value: 137),
        TunerWrite(reg: 21, value: 245),
        TunerWrite(reg: 26, value: 42),
    ]
    #expect(secondTune == expected)
}
