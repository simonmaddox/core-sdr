enum RTLBlock: UInt8 { case demod = 0, usb = 1, sys = 2, tuner = 3, rom = 4, ir = 5, i2c = 6 }

enum RTLRegisters {
    static func writeRequest(block: RTLBlock, addr: UInt16) -> USBControlRequest {
        USBControlRequest(requestType: 0x40, request: 0, value: addr, index: (UInt16(block.rawValue) << 8) | 0x10)
    }
    static func readRequest(block: RTLBlock, addr: UInt16) -> USBControlRequest {
        USBControlRequest(requestType: 0xC0, request: 0, value: addr, index: UInt16(block.rawValue) << 8)
    }
    static func demodWriteRequest(page: UInt8, addr: UInt16) -> USBControlRequest {
        USBControlRequest(requestType: 0x40, request: 0, value: (addr << 8) | 0x20, index: 0x10 | UInt16(page))
    }
    static func demodReadRequest(page: UInt8, addr: UInt16) -> USBControlRequest {
        USBControlRequest(requestType: 0xC0, request: 0, value: (addr << 8) | 0x20, index: UInt16(page))
    }
    static func payload(value: UInt16, length: Int) -> [UInt8] {
        length == 1 ? [UInt8(value & 0xff)] : [UInt8(value >> 8), UInt8(value & 0xff)]
    }
}
