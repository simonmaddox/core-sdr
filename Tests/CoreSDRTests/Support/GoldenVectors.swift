import Foundation
@testable import CoreSDR

/// A single expanded tuner-register write: one register address and the byte
/// programmed into it. Golden vectors and the mock's decoded writes are both
/// expressed as `[TunerWrite]` so they compare with `==`.
struct TunerWrite: Equatable, Decodable, Sendable {
    let reg: UInt8
    let value: UInt8
}

/// One captured `setFreq` golden vector: the requested RF frequency and the
/// exact sequence of tuner register writes the reference emitted.
struct SetFreqVector: Decodable, Sendable {
    let hz: UInt64
    let writes: [TunerWrite]
}

/// One captured `setGain` golden vector: the requested gain (in tenths of a dB,
/// absent for the automatic-mode vector), the capture mode (`"manual"` or
/// `"auto"`), and the exact sequence of tuner register writes the reference
/// emitted from `r82xx_set_gain`.
struct SetGainVector: Decodable, Sendable {
    let tenthsDb: Int?
    let mode: String
    let writes: [TunerWrite]
}

/// Decodes the committed `r820t2_golden.json` fixture (captured from the
/// librtlsdr reference by `scripts/capture-r820t2-golden`) from the test
/// bundle. Models the `setFreq` and `setGain` sections.
struct GoldenVectors: Decodable, Sendable {
    let setFreq: [SetFreqVector]
    let setGain: [SetGainVector]

    static func load() throws -> GoldenVectors {
        guard let url = Bundle.module.url(forResource: "r820t2_golden", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(GoldenVectors.self, from: data)
    }
}

extension MockUSBTransport {
    /// Decodes recorded control writes into the flat `(reg, value)` sequence a
    /// tuner sees. Keeps only IICB block writes addressed to the R820T2
    /// (`value == 0x34`, `index == 0x0610` — i.e. `RTLBlock.i2c` write request),
    /// then expands each transfer's payload `[startReg, v0, v1, ...]` into
    /// consecutive `(startReg + i, v_i)` pairs. Repeater toggles and other
    /// demodulator-side writes are filtered out.
    func tunerRegisterWrites() -> [TunerWrite] {
        var result: [TunerWrite] = []
        for write in controlWrites where write.request.value == 0x34 && write.request.index == 0x0610 {
            guard let startReg = write.data.first else { continue }
            for (offset, value) in write.data.dropFirst().enumerated() {
                result.append(TunerWrite(reg: startReg &+ UInt8(offset), value: value))
            }
        }
        return result
    }
}
