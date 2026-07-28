import Testing
@testable import CoreSDR

@Test func resetBufferTogglesEpaCtl() async throws {
    let m = MockUSBTransport()
    let rtl = RTL2832U(transport: m)
    try await rtl.resetBuffer()
    let writes = m.controlWrites
    #expect(writes.count == 2)
    #expect(writes[0].request.value == 0x2148)
    #expect(writes[0].data == [0x10, 0x02])
    #expect(writes[1].request.value == 0x2148)
    #expect(writes[1].data == [0x00, 0x00])
}
