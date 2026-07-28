import Testing
import Foundation
@testable import CoreSDR

@Test func gainTableHas29Steps() {
    #expect(R820T2.gainStepsTenthsDb.count == 29)
    #expect(R820T2.gainStepsTenthsDb.first == 0)
    #expect(R820T2.gainStepsTenthsDb.last == 496)
}

@Test func setManualGainMatchesGoldenVectors() async throws {
    let golden = try GoldenVectors.load()
    let manual = golden.setGain.filter { $0.mode == "manual" }
    #expect(manual.count == 3)
    for vector in manual {
        let tenths = try #require(vector.tenthsDb)
        let m = MockUSBTransport()
        let r820 = R820T2(rtl: RTL2832U(transport: m))
        try await r820.setManualGain(tenthsDb: tenths)
        #expect(m.tunerRegisterWrites() == vector.writes, "gain \(tenths)")
    }
}

@Test func setAutomaticGainMatchesGoldenVector() async throws {
    let golden = try GoldenVectors.load()
    let auto = try #require(golden.setGain.first { $0.mode == "auto" })
    let m = MockUSBTransport()
    let r820 = R820T2(rtl: RTL2832U(transport: m))
    try await r820.setAutomaticGain()
    #expect(m.tunerRegisterWrites() == auto.writes)
}
