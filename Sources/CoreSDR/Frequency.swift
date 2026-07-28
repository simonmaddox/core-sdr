public struct Frequency: Sendable, Comparable, Hashable {
    public let hertz: UInt64
    public init(hertz: UInt64) { self.hertz = hertz }
    public static func hertz(_ v: UInt64) -> Frequency { Frequency(hertz: v) }
    public static func khz(_ v: Double) -> Frequency { Frequency(hertz: UInt64((v * 1_000).rounded())) }
    public static func mhz(_ v: Double) -> Frequency { Frequency(hertz: UInt64((v * 1_000_000).rounded())) }
    public static func < (a: Frequency, b: Frequency) -> Bool { a.hertz < b.hertz }
}
