import Testing
@testable import CoreSDR

/// The sample pump is decomposed into `resetStreaming()` + `bulkStream(...)` +
/// `makeBlock(...)`, driven as one loop by `SDRDevice`. This exercises those
/// pieces composing correctly: raw transfers pass through and each is stamped
/// with a monotonic sequence and the live center frequency.
@Test func decomposedSampleStreamStampsBlocks() async throws {
    let m = MockUSBTransport()
    m.stubBulk([[10, 20, 30, 40], [50, 60, 70, 80]])
    m.stubTunerPLLLocked()
    let dev = RTLSDRDevice(transport: m)
    try await dev.tune(to: .mhz(100))
    try await dev.resetStreaming()

    var blocks: [IQBlock] = []
    var sequence: UInt64 = 0
    for try await chunk in dev.bulkStream(transferSize: 4, inFlight: 4) {
        blocks.append(dev.makeBlock(raw: chunk, sequence: sequence))
        sequence += 1
        if blocks.count == 2 { break }
    }
    #expect(blocks[0].raw == [10, 20, 30, 40])
    #expect(blocks[0].sequence == 0)
    #expect(blocks[1].sequence == 1)
    #expect(blocks[0].centerFrequency == .mhz(100))
}
