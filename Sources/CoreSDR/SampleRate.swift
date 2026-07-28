public struct SampleRate: Sendable, Comparable, Hashable {
    public let hertz: UInt32
    public init(hertz: UInt32) { self.hertz = hertz }
    public static let rate2_4M = SampleRate(hertz: 2_400_000)
    public static let rate2_048M = SampleRate(hertz: 2_048_000)
    public static func < (a: SampleRate, b: SampleRate) -> Bool { a.hertz < b.hertz }

    public var isResamplerValid: Bool {
        if hertz <= 225_000 || hertz > 3_200_000 { return false }
        if hertz > 300_000 && hertz <= 900_000 { return false }
        return true
    }
}
