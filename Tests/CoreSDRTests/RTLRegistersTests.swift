import Testing
@testable import CoreSDR

@Test func blockWriteEncoding() {
    let r = RTLRegisters.writeRequest(block: .usb, addr: 0x2000)
    #expect(r.requestType == 0x40)
    #expect(r.request == 0)
    #expect(r.value == 0x2000)
    #expect(r.index == 0x0110)          // (1 << 8) | 0x10
}

@Test func blockReadEncoding() {
    let r = RTLRegisters.readRequest(block: .sys, addr: 0x3000)
    #expect(r.requestType == 0xC0)
    #expect(r.index == 0x0200)          // 2 << 8
}

@Test func demodWriteEncoding() {
    let r = RTLRegisters.demodWriteRequest(page: 1, addr: 0x01)
    #expect(r.requestType == 0x40)
    #expect(r.value == 0x0120)          // (0x01 << 8) | 0x20
    #expect(r.index == 0x0011)          // 0x10 | 1
}

@Test func demodReadEncoding() {
    let r = RTLRegisters.demodReadRequest(page: 0x0a, addr: 0x01)
    #expect(r.value == 0x0120)
    #expect(r.index == 0x000a)          // page only
}

@Test func payloadIsBigEndian() {
    #expect(RTLRegisters.payload(value: 0x1002, length: 2) == [0x10, 0x02])
    #expect(RTLRegisters.payload(value: 0x00e8, length: 1) == [0xE8])
}
