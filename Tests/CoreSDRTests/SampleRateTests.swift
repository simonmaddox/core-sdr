import Testing
@testable import CoreSDR

@Test func commonRatesAreValid() {
    #expect(SampleRate(hertz: 2_400_000).isResamplerValid)
    #expect(SampleRate(hertz: 2_048_000).isResamplerValid)
    #expect(SampleRate(hertz: 250_000).isResamplerValid)
}

@Test func outOfBandRatesAreInvalid() {
    #expect(!SampleRate(hertz: 225_000).isResamplerValid)
    #expect(!SampleRate(hertz: 3_200_001).isResamplerValid)
    #expect(!SampleRate(hertz: 600_000).isResamplerValid) // in the 300k–900k hole
}
