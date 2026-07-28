import Testing
@testable import CoreSDR

@Test func megahertzConvertsToHertz() {
    #expect(Frequency.mhz(173.225).hertz == 173_225_000)
}
@Test func kilohertzConvertsToHertz() {
    #expect(Frequency.khz(100).hertz == 100_000)
}
@Test func frequenciesCompareByHertz() {
    #expect(Frequency.mhz(100) < Frequency.mhz(101))
}
