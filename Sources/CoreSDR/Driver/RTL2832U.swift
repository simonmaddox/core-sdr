/// Register-level access to the RTL2832U demodulator/USB bridge chip over
/// any `USBTransport`. Encodes control requests via `RTLRegisters` and
/// combines multi-byte reads little-endian, matching `librtlsdr`.
struct RTL2832U {
    /// Internal accessor so peripheral drivers on the same I2C/USB fabric
    /// (e.g. `R820T2`, which needs to build a raw `[reg] + values` payload
    /// that `writeReg`'s single-value encoding can't express) can issue
    /// control transfers directly.
    let transport: any USBTransport

    init(transport: any USBTransport) {
        self.transport = transport
    }

    /// Write `value` to a register in `block` at `addr`.
    /// Mirrors `rtlsdr_write_reg`.
    func writeReg(_ block: RTLBlock, _ addr: UInt16, _ value: UInt16, length: Int) async throws {
        let request = RTLRegisters.writeRequest(block: block, addr: addr)
        try await transport.controlWrite(request, data: RTLRegisters.payload(value: value, length: length))
    }

    /// Read a register in `block` at `addr`. Bytes are combined little-endian:
    /// `(data[1] << 8) | data[0]`.
    /// Mirrors `rtlsdr_read_reg`.
    func readReg(_ block: RTLBlock, _ addr: UInt16, length: Int) async throws -> UInt16 {
        let request = RTLRegisters.readRequest(block: block, addr: addr)
        let data = try await transport.controlRead(request, length: length)
        return combine(data)
    }

    /// Write `value` to a demodulator register on `page` at `addr`, then
    /// issue a trailing dummy read of page 0x0a, addr 0x01 — matching
    /// `rtlsdr_demod_write_reg`, which the reference driver relies on to
    /// latch the write.
    func demodWrite(page: UInt8, addr: UInt16, value: UInt16, length: Int) async throws {
        let request = RTLRegisters.demodWriteRequest(page: page, addr: addr)
        try await transport.controlWrite(request, data: RTLRegisters.payload(value: value, length: length))
        _ = try await demodRead(page: 0x0a, addr: 0x01, length: 1)
    }

    /// Read a demodulator register on `page` at `addr`. Bytes are combined
    /// little-endian: `(data[1] << 8) | data[0]`.
    /// Mirrors `rtlsdr_demod_read_reg`.
    func demodRead(page: UInt8, addr: UInt16, length: Int) async throws -> UInt16 {
        let request = RTLRegisters.demodReadRequest(page: page, addr: addr)
        let data = try await transport.controlRead(request, length: length)
        return combine(data)
    }

    private func combine(_ data: [UInt8]) -> UInt16 {
        guard data.count >= 2 else {
            return data.first.map(UInt16.init) ?? 0
        }
        return (UInt16(data[1]) << 8) | UInt16(data[0])
    }

    /// Default FIR filter coefficients, packed for `demodWrite`, matching
    /// `fir_default` in the reference driver.
    ///
    /// Source coefficients: eight 8-bit signed values
    /// `[-54, -36, -41, -40, -32, -14, 14, 53]` followed by eight 12-bit
    /// signed values `[101, 156, 215, 273, 327, 372, 404, 421]`. `rtlsdr_set_fir`
    /// writes the 8-bit values as-is (bytes 0-7) and packs the 12-bit values
    /// two at a time as `[v0>>4, (v0<<4)|((v1>>8)&0x0f), v1]` (bytes 8-19).
    static let firDefault: [UInt8] = [
        0xca, 0xdc, 0xd7, 0xd8, 0xe0, 0xf2, 0x0e, 0x35,
        0x06, 0x50, 0x9c, 0x0d, 0x71, 0x11, 0x14, 0x71,
        0x74, 0x19, 0x41, 0xa5,
    ]

    /// Powers on and configures the demodulator: USB packet sizing, demod
    /// power/reset, IF/DDC clearing, the default FIR filter, and the
    /// SDR-mode/AGC/PID register set. Mirrors `rtlsdr_init_baseband`; the
    /// order of writes below is authoritative and must not be reordered.
    func initBaseband() async throws {
        // Initialize USB.
        try await writeReg(.usb, 0x2000, 0x09, length: 1) // USB_SYSCTL
        try await writeReg(.usb, 0x2158, 0x0002, length: 2) // USB_EPA_MAXPKT
        try await writeReg(.usb, 0x2148, 0x1002, length: 2) // USB_EPA_CTL

        // Power on demod.
        try await writeReg(.sys, 0x300b, 0x22, length: 1) // DEMOD_CTL_1
        try await writeReg(.sys, 0x3000, 0xe8, length: 1) // DEMOD_CTL

        // Reset demod (bit 3, soft_rst).
        try await demodWrite(page: 1, addr: 0x01, value: 0x14, length: 1)
        try await demodWrite(page: 1, addr: 0x01, value: 0x10, length: 1)

        // Disable spectrum inversion and adjacent channel rejection.
        try await demodWrite(page: 1, addr: 0x15, value: 0x00, length: 1)
        try await demodWrite(page: 1, addr: 0x16, value: 0x0000, length: 2)

        // Clear both DDC shift and IF frequency registers.
        for i: UInt16 in 0..<6 {
            try await demodWrite(page: 1, addr: 0x16 + i, value: 0x00, length: 1)
        }

        // Set FIR filter (rtlsdr_set_fir).
        for (i, byte) in Self.firDefault.enumerated() {
            try await demodWrite(page: 1, addr: 0x1c + UInt16(i), value: UInt16(byte), length: 1)
        }

        // Enable SDR mode, disable DAGC (bit 5).
        try await demodWrite(page: 0, addr: 0x19, value: 0x05, length: 1)

        // Init FSM state-holding register.
        try await demodWrite(page: 1, addr: 0x93, value: 0xf0, length: 1)
        try await demodWrite(page: 1, addr: 0x94, value: 0x0f, length: 1)

        // Disable AGC (en_dagc, bit 0) (this seems to have no effect).
        try await demodWrite(page: 1, addr: 0x11, value: 0x00, length: 1)

        // Disable RF and IF AGC loop.
        try await demodWrite(page: 1, addr: 0x04, value: 0x00, length: 1)

        // Disable PID filter (enable_PID = 0).
        try await demodWrite(page: 0, addr: 0x61, value: 0x60, length: 1)

        // opt_adc_iq = 0, default ADC_I/Q sequence.
        try await demodWrite(page: 0, addr: 0x06, value: 0x80, length: 1)

        // Enable Zero-IF mode (en_bbin bit), DC cancellation (en_dc_est),
        // IQ estimation/compensation (en_iq_comp, en_iq_est).
        try await demodWrite(page: 1, addr: 0xb1, value: 0x1b, length: 1)

        // Disable 4.096 MHz clock output on pin TP_CK0.
        try await demodWrite(page: 0, addr: 0x0d, value: 0x83, length: 1)
    }

    /// Computes the demodulator resampler ratio for `sampleRate` given the
    /// tuner crystal frequency `xtal`. Mirrors the ratio computation in
    /// `rtlsdr_set_sample_rate`: `ratio = (xtal << 22) / rate`, with the
    /// low 2 bits masked off.
    static func resamplerRatio(sampleRate: UInt32, xtal: UInt32 = 28_800_000) -> UInt32 {
        let ratio = (UInt64(xtal) << 22) / UInt64(sampleRate)
        return UInt32(ratio) & 0x0fff_fffc
    }

    /// Configures the demodulator resampler for `rate`, then issues the
    /// soft-reset pair to latch the new ratio. Mirrors `rtlsdr_set_sample_rate`.
    func setSampleRate(_ rate: SampleRate) async throws {
        guard rate.isResamplerValid else {
            throw SDRError.unsupportedSampleRate(rate)
        }
        let ratio = Self.resamplerRatio(sampleRate: rate.hertz)
        try await demodWrite(page: 1, addr: 0x9f, value: UInt16(ratio >> 16), length: 2)
        try await demodWrite(page: 1, addr: 0xa1, value: UInt16(ratio & 0xffff), length: 2)

        // Soft-reset (bit 3, soft_rst) to latch the new resampler ratio.
        try await demodWrite(page: 1, addr: 0x01, value: 0x14, length: 1)
        try await demodWrite(page: 1, addr: 0x01, value: 0x10, length: 1)
    }

    /// Programs the demodulator's digital downconverter to translate the
    /// tuner's low-IF (`freqHz`) to baseband. Mirrors `rtlsdr_set_if_freq`:
    /// `if_freq = -((freqHz << 22) / xtal)` as signed 32-bit math (integer
    /// division truncates toward zero), then three 1-byte demod writes to
    /// page 1 addr 0x19/0x1a/0x1b carrying the high 6 bits, middle byte, and
    /// low byte of `if_freq`.
    ///
    /// The masks operate on the two's-complement bit pattern, so a negative
    /// `if_freq` masks correctly (Swift `&`/`>>` on `Int32` are bitwise /
    /// arithmetic-shift over the signed representation).
    func setIFFrequency(_ freqHz: UInt32, xtal: UInt32 = 28_800_000) async throws {
        let ifFreq = Int32(truncatingIfNeeded: -(Int64(freqHz) << 22) / Int64(xtal))
        try await demodWrite(page: 1, addr: 0x19, value: UInt16((ifFreq >> 16) & 0x3f), length: 1)
        try await demodWrite(page: 1, addr: 0x1a, value: UInt16((ifFreq >> 8) & 0xff), length: 1)
        try await demodWrite(page: 1, addr: 0x1b, value: UInt16(ifFreq & 0xff), length: 1)
    }

    /// Switches the demodulator from the zero-IF configuration `initBaseband`
    /// leaves it in to the R820T2's low-IF pipeline: disables Zero-IF mode,
    /// selects the In-phase ADC input only, sets the 3.57 MHz IF downconvert,
    /// and enables spectrum inversion. Mirrors the `RTLSDR_TUNER_R820T` block
    /// in `rtlsdr_open`, which runs AFTER `init_baseband` and tuner init. The
    /// order below is authoritative and must not be reordered.
    func configureForR820T2() async throws {
        try await demodWrite(page: 1, addr: 0xb1, value: 0x1a, length: 1) // disable Zero-IF mode
        try await demodWrite(page: 0, addr: 0x08, value: 0x4d, length: 1) // only enable In-phase ADC input
        try await setIFFrequency(3_570_000)                               // R82XX 3.57 MHz IF
        try await demodWrite(page: 1, addr: 0x15, value: 0x01, length: 1) // enable spectrum inversion
    }

    /// Resets the USB endpoint buffer before streaming by toggling the EPA_CTL
    /// register. Mirrors `rtlsdr_reset_buffer`.
    func resetBuffer() async throws {
        try await writeReg(.usb, 0x2148, 0x1002, length: 2)
        try await writeReg(.usb, 0x2148, 0x0000, length: 2)
    }
}
