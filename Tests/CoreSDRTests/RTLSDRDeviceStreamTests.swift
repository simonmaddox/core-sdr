import Testing
@testable import CoreSDR

@Test func samplesWrapBulkChunksAsSequencedBlocks() async throws {
    let m = MockUSBTransport()
    m.stubBulk([[10, 20, 30, 40], [50, 60, 70, 80]])
    m.stubTunerPLLLocked()
    let dev = RTLSDRDevice(transport: m)
    try await dev.tune(to: .mhz(100))
    var blocks: [IQBlock] = []
    for try await b in dev.samples(transferSize: 4, inFlight: 4) {
        blocks.append(b)
        if blocks.count == 2 { break }
    }
    #expect(blocks[0].raw == [10, 20, 30, 40])
    #expect(blocks[0].sequence == 0)
    #expect(blocks[1].sequence == 1)
    #expect(blocks[0].centerFrequency == .mhz(100))
}
