import Testing
@testable import CoreSDR

@Test func initBasebandEmitsExactSequence() async throws {
    let m = MockUSBTransport()
    let rtl = RTL2832U(transport: m)
    try await rtl.initBaseband()

    // Spot-check the framing writes (block writes only; ignore demod dummy reads).
    let firstThree = Array(m.controlWrites.prefix(3))
    #expect(firstThree[0].request.value == 0x2000 && firstThree[0].data == [0x09])
    #expect(firstThree[1].request.value == 0x2158 && firstThree[1].data == [0x00, 0x02])
    #expect(firstThree[2].request.value == 0x2148 && firstThree[2].data == [0x10, 0x02])

    // FIR: 20 consecutive demod writes to page 1, addr 0x1c..0x2f.
    let firWrites = m.controlWrites.filter { $0.request.index == 0x0011 && $0.request.value >= 0x1c20 && $0.request.value <= 0x2f20 }
    #expect(firWrites.count == 20)
    #expect(firWrites.first?.data == [0xca])
    #expect(firWrites.last?.data == [0xa5])

    // Final baseband write: D(0,0x0d,0x83,1) → value 0x0d20, index 0x0010, data [0x83]
    let last = m.controlWrites.last!
    #expect(last.request.value == 0x0d20 && last.request.index == 0x0010 && last.data == [0x83])
}
