public struct SDRCapabilities: Sendable {
    public let frequencyRange: ClosedRange<Frequency>
    public let supportedSampleRates: [SampleRate]
    public let gainSteps: [Float]
    public init(frequencyRange: ClosedRange<Frequency>, supportedSampleRates: [SampleRate], gainSteps: [Float]) {
        self.frequencyRange = frequencyRange
        self.supportedSampleRates = supportedSampleRates
        self.gainSteps = gainSteps
    }
    public func nearestGainStep(to dB: Float) -> Float {
        gainSteps.min(by: { abs($0 - dB) < abs($1 - dB) }) ?? dB
    }
}
