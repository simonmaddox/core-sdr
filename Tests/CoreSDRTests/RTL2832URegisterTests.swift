import Testing
@testable import CoreSDR

@Test func writeRegForwardsEncodedRequestAndPayload() async throws {
    let m = MockUSBTransport()
    let rtl = RTL2832U(transport: m)
    try await rtl.writeReg(.usb, 0x2000, 0x09, length: 1)
    #expect(m.controlWrites.count == 1)
    #expect(m.controlWrites[0].request.index == 0x0110)
    #expect(m.controlWrites[0].data == [0x09])
}

@Test func demodWriteEmitsWriteThenDummyRead() async throws {
    let m = MockUSBTransport()
    let rtl = RTL2832U(transport: m)
    try await rtl.demodWrite(page: 1, addr: 0x01, value: 0x14, length: 1)
    #expect(m.controlWrites.count == 1)
    #expect(m.controlWrites[0].request.value == 0x0120)
    #expect(m.controlWrites[0].data == [0x14])
    // dummy read of page 0x0a addr 0x01
    #expect(m.controlReads.last?.request.index == 0x000a)
    #expect(m.controlReads.last?.request.value == 0x0120)
}
