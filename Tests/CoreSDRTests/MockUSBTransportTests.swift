import Testing
@testable import CoreSDR

@Test func mockRecordsControlWritesInOrder() async throws {
    let m = MockUSBTransport()
    try await m.controlWrite(.init(requestType: 0x40, request: 0, value: 0x2000, index: 0x0110), data: [0x09])
    #expect(m.controlWrites.count == 1)
    #expect(m.controlWrites[0].request.value == 0x2000)
    #expect(m.controlWrites[0].data == [0x09])
}

@Test func mockReturnsStubbedRead() async throws {
    let m = MockUSBTransport()
    m.stubRead(value: 0x0001, index: 0x000a, returns: [0xAB])
    let out = try await m.controlRead(.init(requestType: 0xC0, request: 0, value: 0x0001, index: 0x000a), length: 1)
    #expect(out == [0xAB])
}

@Test func mockStreamsCannedBulkChunks() async throws {
    let m = MockUSBTransport()
    m.stubBulk([[0, 1, 2, 3], [4, 5, 6, 7]])
    var got: [[UInt8]] = []
    for try await chunk in m.bulkStream(endpoint: 0x81, transferSize: 4, inFlight: 1) {
        got.append(chunk)
        if got.count == 2 { break }
    }
    #expect(got == [[0, 1, 2, 3], [4, 5, 6, 7]])
}
