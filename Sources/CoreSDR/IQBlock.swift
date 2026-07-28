import Accelerate

/// A block of raw interleaved IQ samples captured from the RTL2832U, plus metadata.
///
/// `raw` is the lossless source of truth: interleaved unsigned 8-bit bytes (I,Q,I,Q,...)
/// exactly as delivered by the dongle. Use `normalized()` to convert on demand to
/// interleaved `Float32` samples in the range [-1, 1].
public struct IQBlock: Sendable {
    public let raw: [UInt8]
    public let sampleRate: SampleRate
    public let centerFrequency: Frequency
    public let sequence: UInt64
    public let hostTimestamp: UInt64

    public init(
        raw: [UInt8],
        sampleRate: SampleRate,
        centerFrequency: Frequency,
        sequence: UInt64,
        hostTimestamp: UInt64
    ) {
        self.raw = raw
        self.sampleRate = sampleRate
        self.centerFrequency = centerFrequency
        self.sequence = sequence
        self.hostTimestamp = hostTimestamp
    }

    /// Converts the raw interleaved bytes to interleaved `Float32` samples in [-1, 1]
    /// via `out = (Float(byte) - 127.5) / 127.5`.
    public func normalized() -> [Float] {
        let count = raw.count
        guard count > 0 else { return [] }

        var floats = [Float](repeating: 0, count: count)
        vDSP_vfltu8(raw, 1, &floats, 1, vDSP_Length(count))

        var result = [Float](repeating: 0, count: count)
        var scale: Float = 1.0 / 127.5
        var offset: Float = -127.5 / 127.5
        vDSP_vsmsa(floats, 1, &scale, &offset, &result, 1, vDSP_Length(count))
        return result
    }
}
