public struct Frequency: Sendable, Comparable, Hashable {
    public let hertz: UInt64
    public init(hertz: UInt64) { self.hertz = hertz }
    public static func hertz(_ v: UInt64) -> Frequency { Frequency(hertz: v) }

    /// Constructs a `Frequency` from a value in kilohertz. Negative, NaN, and
    /// other non-finite inputs are clamped to 0 Hz, and values beyond
    /// `UInt64.max` hertz clamp to `UInt64.max`, rather than trapping —
    /// this is a public entry point that can see unvalidated caller input
    /// (e.g. parsed text), and it shouldn't be able to crash the host app.
    public static func khz(_ v: Double) -> Frequency { Frequency(hertz: Self.clampedHertz(v * 1_000)) }

    /// Constructs a `Frequency` from a value in megahertz. Negative, NaN, and
    /// other non-finite inputs are clamped to 0 Hz, and values beyond
    /// `UInt64.max` hertz clamp to `UInt64.max`, rather than trapping —
    /// this is a public entry point that can see unvalidated caller input
    /// (e.g. parsed text), and it shouldn't be able to crash the host app.
    public static func mhz(_ v: Double) -> Frequency { Frequency(hertz: Self.clampedHertz(v * 1_000_000)) }

    public static func < (a: Frequency, b: Frequency) -> Bool { a.hertz < b.hertz }

    /// Rounds `v` and clamps it into `UInt64`'s representable range,
    /// treating negative and non-finite (NaN, ±infinity) values as 0.
    private static func clampedHertz(_ v: Double) -> UInt64 {
        guard v.isFinite, v > 0 else { return 0 }
        let rounded = v.rounded()
        guard rounded < Double(UInt64.max) else { return UInt64.max }
        return UInt64(rounded)
    }
}
