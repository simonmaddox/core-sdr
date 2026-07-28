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
