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

@Test func negativeMegahertzClampsToZero() {
    #expect(Frequency.mhz(-1).hertz == 0)
}
@Test func negativeKilohertzClampsToZero() {
    #expect(Frequency.khz(-100).hertz == 0)
}
@Test func nanMegahertzClampsToZero() {
    #expect(Frequency.mhz(.nan).hertz == 0)
}
@Test func nanKilohertzClampsToZero() {
    #expect(Frequency.khz(.nan).hertz == 0)
}
@Test func infiniteMegahertzClampsToZero() {
    #expect(Frequency.mhz(.infinity).hertz == 0)
    #expect(Frequency.mhz(-.infinity).hertz == 0)
}
@Test func infiniteKilohertzClampsToZero() {
    #expect(Frequency.khz(.infinity).hertz == 0)
    #expect(Frequency.khz(-.infinity).hertz == 0)
}
@Test func zeroMegahertzIsZero() {
    #expect(Frequency.mhz(0).hertz == 0)
}
@Test func overflowingMegahertzClampsToMax() {
    #expect(Frequency.mhz(1e300).hertz == UInt64.max)
    #expect(Frequency.khz(1e300).hertz == UInt64.max)
}
