import Testing
@testable import CoreSDR

@Test func initArrayIs27Bytes() {
    #expect(R820T2.initArray.count == 27)
    #expect(R820T2.initArray.first == 0x80)
    #expect(R820T2.initArray.last == 0x40)
}
@Test func initializeWrapsWritesInI2cRepeater() async throws {
    let m = MockUSBTransport()
    let r820 = R820T2(rtl: RTL2832U(transport: m))
    try await r820.initialize()
    // First demod write enables repeater (D(1,0x01,0x18)); a later one disables (D(1,0x01,0x10)).
    let demodTo01 = m.controlWrites.filter { $0.request.value == 0x0120 && $0.request.index == 0x0011 }
    #expect(demodTo01.first?.data == [0x18])
    #expect(demodTo01.last?.data == [0x10])
    // At least one IICB write to tuner address 0x34 carrying reg 0x05 as first byte.
    let i2cWrites = m.controlWrites.filter { $0.request.index == 0x0610 && $0.request.value == 0x34 }
    #expect(i2cWrites.contains { $0.data.first == 0x05 })
}

/// Pins the exact chunk boundary of the 27-byte tuner init-array write. The
/// RTL2832U STALLs I2C block writes over 16 bytes, so `writeRegisters` must
/// split the run into 16 + 13 byte transfers, re-emitting the incrementing
/// start register. This fails against a broken chunker (a single 28-byte
/// write, a wrong `maxValues`, or an off-by-one register increment) and passes
/// against the current one.
@Test func initializeChunksTunerWriteWithin16ByteI2CLimit() async throws {
    let m = MockUSBTransport()
    let r820 = R820T2(rtl: RTL2832U(transport: m))
    try await r820.initialize()

    let i2cWrites = m.controlWrites
        .filter { $0.request.index == 0x0610 && $0.request.value == 0x34 }

    // 27 init-array values → two transfers: [0x05]+15 (16B) and [0x14]+12 (13B).
    #expect(i2cWrites.count == 2)
    #expect(i2cWrites[0].data.count == 16)
    #expect(i2cWrites[0].data.first == 0x05)
    #expect(i2cWrites[1].data.count == 13)
    #expect(i2cWrites[1].data.first == 0x14)

    // No transfer may exceed the hardware's 16-byte I2C limit.
    #expect(i2cWrites.allSatisfy { $0.data.count <= R820T2.maxI2CTransferBytes })

    // Reconstruct the (register, value) pairs across the boundary and prove the
    // full consecutive run 0x05…0x1f is written with initArray's values — no
    // byte dropped, duplicated, or mis-addressed by the split.
    var written: [UInt8: UInt8] = [:]
    for write in i2cWrites {
        let startReg = write.data[0]
        for (offset, value) in write.data.dropFirst().enumerated() {
            written[startReg + UInt8(offset)] = value
        }
    }
    var expected: [UInt8: UInt8] = [:]
    for (offset, value) in R820T2.initArray.enumerated() {
        expected[0x05 + UInt8(offset)] = value
    }
    #expect(written == expected)
    #expect(written.keys.sorted() == Array(UInt8(0x05)...UInt8(0x1f)))
}
