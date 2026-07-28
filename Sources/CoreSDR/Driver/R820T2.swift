/// Register-level access to the R820T2 tuner, which sits on an I2C bus
/// behind the RTL2832U. Tuner register writes are issued as USB control
/// transfers on the RTL2832U's IICB block (`.i2c`), addressed to the
/// tuner's fixed I2C address, with the target register as the first
/// payload byte (`[reg] + values`) — the RTL2832U itself just proxies the
/// I2C bus, so this is not expressible via `RTL2832U.writeReg`'s
/// single-value-per-address encoding.
///
/// Because the RTL2832U's I2C master is normally reserved for its own
/// demodulator-side use, tuner access must be bracketed by toggling the
/// demodulator's "I2C repeater" bit, mirroring `rtlsdr_set_i2c_repeater`.
struct R820T2 {
    /// Fixed I2C address of the R820T2 tuner on the RTL2832U's I2C bus.
    static let i2cAddress: UInt16 = 0x34

    /// Maximum payload of a single IICB control transfer, in bytes, including
    /// the leading register-address byte. The RTL2832U's I2C block write
    /// accepts at most 16 bytes per transfer; the device STALLs the control
    /// endpoint (`kUSBHostReturnPipeStalled`, 0xe0005000) on anything longer.
    /// Mirrors `librtlsdr`'s `max_i2c_msg_len = 16`, which chunks `r82xx_write`
    /// into runs of `max_i2c_msg_len - 1` (15) register values, re-emitting the
    /// incrementing start register for each chunk. Verified live: a 16-byte
    /// payload succeeds, 17 bytes STALLs.
    static let maxI2CTransferBytes = 16

    /// Register values for regs 0x05...0x1f (27 bytes), transcribed from
    /// `librtlsdr`'s `r82xx_init` table (`DEFAULT_IF_VGA_VAL` folded into
    /// reg 0x0c as `0xe0 | 11 = 0xeb`; reg 0x13 = `VER_NUM & 0x3f` = `0x31`
    /// for `VER_NUM = 49`).
    static let initArray: [UInt8] = [
        0x80, 0x13, 0x70, 0xc0, 0x40, 0xdb, 0x6b, 0xeb,
        0x53, 0x75, 0x68, 0x6c, 0xbb, 0x80, 0x31, 0x0f,
        0x00, 0xc0, 0x30, 0x48, 0xec, 0x60, 0x00, 0x24,
        0xdd, 0x0e, 0x40,
    ]

    private let rtl: RTL2832U

    init(rtl: RTL2832U) {
        self.rtl = rtl
    }

    /// Writes a single tuner register.
    func writeRegister(_ reg: UInt8, _ value: UInt8) async throws {
        try await writeRegisters(startReg: reg, [value])
    }

    /// Writes a consecutive block of tuner registers starting at `startReg`,
    /// as IICB control transfers with payload `[reg] + values`. Splits runs
    /// longer than `maxI2CTransferBytes - 1` values into multiple transfers
    /// (re-emitting the incrementing start register each time), because the
    /// RTL2832U STALLs I2C block writes above 16 payload bytes — matching
    /// `librtlsdr`'s chunked `r82xx_write`. The R820T2 auto-increments its
    /// register pointer within a transfer, so the split is transparent: each
    /// register still receives its value.
    func writeRegisters(startReg: UInt8, _ values: [UInt8]) async throws {
        let request = RTLRegisters.writeRequest(block: .i2c, addr: Self.i2cAddress)
        let maxValues = Self.maxI2CTransferBytes - 1  // reserve one byte for the register
        var reg = startReg
        var offset = 0
        repeat {
            let end = min(offset + maxValues, values.count)
            try await rtl.transport.controlWrite(request, data: [reg] + values[offset..<end])
            reg = reg &+ UInt8(end - offset)
            offset = end
        } while offset < values.count
    }

    /// Reverses the bit order of a byte, mirroring `r82xx_bitrev`: the R820T2
    /// clocks each register byte out MSB-first over I2C, so the driver must
    /// bit-reverse every byte it reads back.
    static func bitReverse(_ byte: UInt8) -> UInt8 {
        let lut: [UInt8] = [0x0, 0x8, 0x4, 0xc, 0x2, 0xa, 0x6, 0xe,
                            0x1, 0x9, 0x5, 0xd, 0x3, 0xb, 0x7, 0xf]
        return (lut[Int(byte & 0xf)] << 4) | lut[Int(byte >> 4)]
    }

    /// Reads `count` consecutive tuner registers starting at reg 0x00, as one
    /// IICB block read, bit-reversing each returned byte. Mirrors `r82xx_read`
    /// (which always reads from reg 0 and reverses via `r82xx_bitrev`).
    func readRegisters(count: Int) async throws -> [UInt8] {
        let request = RTLRegisters.readRequest(block: .i2c, addr: Self.i2cAddress)
        let raw = try await rtl.transport.controlRead(request, length: count)
        return raw.prefix(count).map { Self.bitReverse($0) }
    }

    /// Enables the I2C repeater, writes `initArray` starting at reg 0x05,
    /// then disables the repeater. Mirrors the tuner init sequence in
    /// `r82xx_init` (via `rtlsdr_set_i2c_repeater` around the writes).
    func initialize() async throws {
        try await setRepeater(enabled: true)
        try await writeRegisters(startReg: 0x05, Self.initArray)
        try await setRepeater(enabled: false)
    }

    // MARK: - Frequency (PLL) tuning

    /// The intermediate frequency the tuner delivers towards the RTL2832U,
    /// in Hz (`priv->int_freq`, set to `3570 * 1000` by `r82xx_set_tv_standard`).
    private static let intFreq: UInt64 = 3_570_000

    /// One entry of the reference `freq_ranges[]` table, driving RF-band /
    /// tracking-filter register programming in `r82xx_set_mux`.
    private struct FreqRange {
        let freqMHz: UInt32      // start freq, in MHz
        let openD: UInt8         // R23[3] open drain (mask 0x08)
        let rfMuxPoly: UInt8     // R26[7:6],[1:0] tracking filter (mask 0xc3)
        let tfC: UInt8           // R27 tracking-filter band (full byte)
        let xtalCap20p: UInt8
        let xtalCap10p: UInt8
        let xtalCap0p: UInt8
    }

    /// Reference `freq_ranges[]` (Rafael R820T), transcribed verbatim from
    /// `tuner_r82xx.c`. `r82xx_set_mux` selects the last entry whose start
    /// frequency does not exceed the LO frequency (in MHz).
    private static let freqRanges: [FreqRange] = [
        FreqRange(freqMHz: 0,   openD: 0x08, rfMuxPoly: 0x02, tfC: 0xdf, xtalCap20p: 0x02, xtalCap10p: 0x01, xtalCap0p: 0x00),
        FreqRange(freqMHz: 50,  openD: 0x08, rfMuxPoly: 0x02, tfC: 0xbe, xtalCap20p: 0x02, xtalCap10p: 0x01, xtalCap0p: 0x00),
        FreqRange(freqMHz: 55,  openD: 0x08, rfMuxPoly: 0x02, tfC: 0x8b, xtalCap20p: 0x02, xtalCap10p: 0x01, xtalCap0p: 0x00),
        FreqRange(freqMHz: 60,  openD: 0x08, rfMuxPoly: 0x02, tfC: 0x7b, xtalCap20p: 0x02, xtalCap10p: 0x01, xtalCap0p: 0x00),
        FreqRange(freqMHz: 65,  openD: 0x08, rfMuxPoly: 0x02, tfC: 0x69, xtalCap20p: 0x02, xtalCap10p: 0x01, xtalCap0p: 0x00),
        FreqRange(freqMHz: 70,  openD: 0x08, rfMuxPoly: 0x02, tfC: 0x58, xtalCap20p: 0x02, xtalCap10p: 0x01, xtalCap0p: 0x00),
        FreqRange(freqMHz: 75,  openD: 0x00, rfMuxPoly: 0x02, tfC: 0x44, xtalCap20p: 0x02, xtalCap10p: 0x01, xtalCap0p: 0x00),
        FreqRange(freqMHz: 80,  openD: 0x00, rfMuxPoly: 0x02, tfC: 0x44, xtalCap20p: 0x02, xtalCap10p: 0x01, xtalCap0p: 0x00),
        FreqRange(freqMHz: 90,  openD: 0x00, rfMuxPoly: 0x02, tfC: 0x34, xtalCap20p: 0x01, xtalCap10p: 0x01, xtalCap0p: 0x00),
        FreqRange(freqMHz: 100, openD: 0x00, rfMuxPoly: 0x02, tfC: 0x34, xtalCap20p: 0x01, xtalCap10p: 0x01, xtalCap0p: 0x00),
        FreqRange(freqMHz: 110, openD: 0x00, rfMuxPoly: 0x02, tfC: 0x24, xtalCap20p: 0x01, xtalCap10p: 0x01, xtalCap0p: 0x00),
        FreqRange(freqMHz: 120, openD: 0x00, rfMuxPoly: 0x02, tfC: 0x24, xtalCap20p: 0x01, xtalCap10p: 0x01, xtalCap0p: 0x00),
        FreqRange(freqMHz: 140, openD: 0x00, rfMuxPoly: 0x02, tfC: 0x14, xtalCap20p: 0x01, xtalCap10p: 0x01, xtalCap0p: 0x00),
        FreqRange(freqMHz: 180, openD: 0x00, rfMuxPoly: 0x02, tfC: 0x13, xtalCap20p: 0x00, xtalCap10p: 0x00, xtalCap0p: 0x00),
        FreqRange(freqMHz: 220, openD: 0x00, rfMuxPoly: 0x02, tfC: 0x13, xtalCap20p: 0x00, xtalCap10p: 0x00, xtalCap0p: 0x00),
        FreqRange(freqMHz: 250, openD: 0x00, rfMuxPoly: 0x02, tfC: 0x11, xtalCap20p: 0x00, xtalCap10p: 0x00, xtalCap0p: 0x00),
        FreqRange(freqMHz: 280, openD: 0x00, rfMuxPoly: 0x02, tfC: 0x00, xtalCap20p: 0x00, xtalCap10p: 0x00, xtalCap0p: 0x00),
        FreqRange(freqMHz: 310, openD: 0x00, rfMuxPoly: 0x41, tfC: 0x00, xtalCap20p: 0x00, xtalCap10p: 0x00, xtalCap0p: 0x00),
        FreqRange(freqMHz: 450, openD: 0x00, rfMuxPoly: 0x41, tfC: 0x00, xtalCap20p: 0x00, xtalCap10p: 0x00, xtalCap0p: 0x00),
        FreqRange(freqMHz: 588, openD: 0x00, rfMuxPoly: 0x40, tfC: 0x00, xtalCap20p: 0x00, xtalCap10p: 0x00, xtalCap0p: 0x00),
        FreqRange(freqMHz: 650, openD: 0x00, rfMuxPoly: 0x40, tfC: 0x00, xtalCap20p: 0x00, xtalCap10p: 0x00, xtalCap0p: 0x00),
    ]

    /// Register shadow (`priv->regs`, indexed by register number 0x00...0x1f)
    /// as it stands after a full `r82xx_init` — the state the reference PLL
    /// routines read-modify-write against. It is seeded from `initArray`
    /// (regs 0x05...0x1f) with two registers overwritten to their post-init
    /// values (the init-time filter calibration and AGC/PLL-autotune setup
    /// leave them changed):
    ///   - 0x10: `0x6c` -> `0x8c` — calibration `r82xx_set_pll` programs
    ///     `div_num = 4` into bits [7:5] (`4 << 5 = 0x80`), keeping the low
    ///     bits `0x6c & 0x1f = 0x0c`, giving `0x8c`.
    ///   - 0x1a: `0x60` -> `0x68` — calibration `r82xx_set_pll` sets PLL
    ///     autotune = 8 kHz (bit 0x08), and `r82xx_sysfreq_sel` sets AGC clk
    ///     60 Hz (bits [5:4] = 0x20), giving `0x68`.
    /// The registers read by `set_mux`/`set_pll` (0x10, 0x12, 0x17, 0x1a)
    /// therefore start at 0x8c, 0x80, 0x30, 0x68 respectively — matching the
    /// deterministic tuner state the golden capture harness produced.
    private static func postInitShadow() -> [UInt8] {
        var regs = [UInt8](repeating: 0, count: 32)
        for (offset, value) in initArray.enumerated() {
            regs[0x05 + offset] = value
        }
        regs[0x10] = 0x8c
        regs[0x1a] = 0x68
        return regs
    }

    /// VCO current programmed into reg 0x12 bits [7:5] at the end of init
    /// (`priv->last_vco_curr = init_array[0x12] & 0xe0 = 0x80`).
    private static let postInitVcoCurr: UInt8 = 0x80

    /// Tunes the tuner PLL to `hz`, reproducing the reference
    /// `r82xx_set_freq64` -> `r82xx_set_mux` + `r82xx_set_pll` write sequence.
    ///
    /// This models a freshly-initialised R820T (matching the golden capture,
    /// which re-runs `r82xx_init` before each vector): the register shadow
    /// starts at `postInitShadow()`, and it targets the non-V4, no-harmonic,
    /// lower-sideband case (`nth_harm = 0`, `sideband = 0`), so the LO
    /// frequency is `hz + intFreq`. Chip status registers are read live over
    /// USB (`readRegisters`), driving `vco_fine_tune` (the `div_num` nudge and
    /// its 0x10 write) and the PLL-lock retry (which can emit an extra 0x12
    /// VCO-current write), exactly as the reference does. All register writes
    /// are bracketed by the I2C repeater, as the reference driver does at the
    /// `rtlsdr` layer.
    func setFrequency(_ hz: UInt64, xtal: UInt32 = 28_800_000) async throws {
        var shadow = Self.postInitShadow()
        var lastVcoCurr = Self.postInitVcoCurr

        // r82xx_set_freq64: sideband 0, tuner_harmonic 0 -> LO is additive.
        let loFreq = hz + Self.intFreq // + if_band_center_freq (0)

        try await setRepeater(enabled: true)
        try await setMux(loFreq: loFreq, shadow: &shadow)
        try await setPLL(loFreq: loFreq, xtal: xtal, shadow: &shadow, lastVcoCurr: &lastVcoCurr)
        try await setRepeater(enabled: false)
    }

    /// Read-modify-write of a masked register against the shadow, mirroring
    /// `r82xx_write_reg_mask`: `val = (shadow & ~mask) | (val & mask)`, storing
    /// the result to the shadow and emitting it over I2C.
    private func writeRegisterMask(_ reg: UInt8, _ value: UInt8, mask: UInt8,
                                   shadow: inout [UInt8]) async throws {
        let merged = (shadow[Int(reg)] & ~mask) | (value & mask)
        shadow[Int(reg)] = merged
        try await writeRegister(reg, merged)
    }

    /// Full (unmasked) register write that also updates the shadow, mirroring
    /// `r82xx_write_reg`.
    private func writeRegisterShadowed(_ reg: UInt8, _ value: UInt8,
                                       shadow: inout [UInt8]) async throws {
        shadow[Int(reg)] = value
        try await writeRegister(reg, value)
    }

    /// Ports `r82xx_set_mux`: programs the RF band / tracking-filter registers
    /// (0x17, 0x1a, 0x1b, 0x10) from the `freq_ranges` entry selected by the
    /// LO frequency.
    private func setMux(loFreq: UInt64, shadow: inout [UInt8]) async throws {
        let freqMHz = UInt32(loFreq / 1_000_000)

        // Last range whose start frequency does not exceed freqMHz.
        var range = Self.freqRanges[0]
        for candidate in Self.freqRanges {
            if candidate.freqMHz <= freqMHz {
                range = candidate
            } else {
                break
            }
        }

        // Open Drain (R23[3]).
        try await writeRegisterMask(0x17, range.openD, mask: 0x08, shadow: &shadow)
        // RF_MUX, Polymux (R26[7:6],[1:0]).
        try await writeRegisterMask(0x1a, range.rfMuxPoly, mask: 0xc3, shadow: &shadow)
        // TF band (R27, full byte).
        try await writeRegisterShadowed(0x1b, range.tfC, shadow: &shadow)
        // XTAL cap & drive (R16[3],[1:0]). Post-init xtal_cap_sel is
        // XTAL_HIGH_CAP_0P, so val = xtal_cap0p | 0x00.
        let capVal = range.xtalCap0p
        try await writeRegisterMask(0x10, capVal, mask: 0x0b, shadow: &shadow)
    }

    /// Ports `r82xx_set_pll` (the default `vco_algo == 0` path): reference
    /// divider, VCO-band search for `mix_div`, integer `nint` + 16-bit
    /// fractional `sdm`, and the register writes to 0x10/0x1a/0x14/0x12/0x16/
    /// 0x15/0x1a. Chip reads are modelled from the harness's deterministic
    /// image (`vco_fine_tune = 2`, PLL locked).
    private func setPLL(loFreq: UInt64, xtal: UInt32,
                        shadow: inout [UInt8], lastVcoCurr: inout UInt8) async throws {
        let vcoMin: UInt64 = 1_770_000            // kHz
        let vcoMax: UInt64 = vcoMin * 2           // kHz (vco_algo == 0)
        let freqKHz = (loFreq + 500) / 1000
        let pllRef = UInt64(xtal)

        let vcoCurrMin: UInt8 = 0x80              // cfg->vco_curr_min == 0xff -> 0x80
        let vcoCurrMax: UInt8 = 0x60              // cfg->vco_curr_max == 0xff -> 0x60
        let vcoPowerRef: UInt8 = 2                // R820T (not R828D)

        // refdiv2 = 0 (R16[4]).
        try await writeRegisterMask(0x10, 0x00, mask: 0x10, shadow: &shadow)
        // PLL autotune = 128 kHz (R26[3:2]).
        try await writeRegisterMask(0x1a, 0x00, mask: 0x0c, shadow: &shadow)
        // Set VCO current (R18[7:5]) only if it changed since last time.
        if lastVcoCurr != vcoCurrMin {
            try await writeRegisterMask(0x12, vcoCurrMin, mask: 0xe0, shadow: &shadow)
            lastVcoCurr = vcoCurrMin
        }

        // VCO-band search: smallest mix_div (2,4,...,64) placing the VCO in band.
        var mixDiv: UInt64 = 2
        var divNum: Int = 0
        while mixDiv <= 64 {
            if freqKHz * mixDiv >= vcoMin && freqKHz * mixDiv < vcoMax {
                var divBuf = mixDiv
                while divBuf > 2 {
                    divBuf >>= 1
                    divNum += 1
                }
                break
            }
            mixDiv <<= 1
        }

        // Live read of regs 0x00..0x04; vco_fine_tune = (reg4 & 0x30) >> 4.
        let statusData = try await readRegisters(count: 5)
        let vcoFineTune = (statusData[4] & 0x30) >> 4
        if vcoFineTune > vcoPowerRef {
            divNum -= 1
        } else if vcoFineTune < vcoPowerRef {
            divNum += 1
        }

        // div_num into R16[7:5].
        try await writeRegisterMask(0x10, UInt8(divNum) << 5, mask: 0xe0, shadow: &shadow)

        // Approximate vco_freq / (2 * pll_ref) as nint + sdm/65536.
        let vcoFreq = loFreq * mixDiv
        let vcoDiv = (pllRef + 65536 * vcoFreq) / (2 * pllRef)
        let nint = UInt32(vcoDiv / 65536)
        let sdm = UInt32(vcoDiv % 65536)

        // nint must fit; guaranteed for the supported band.
        guard nint <= (128 / UInt32(vcoPowerRef)) - 1 else {
            throw SDRError.tuningOutOfRange(Frequency(hertz: loFreq))
        }

        let ni = (nint - 13) / 4
        let si = nint - 4 * ni - 13
        try await writeRegisterShadowed(0x14, UInt8(ni) | (UInt8(si) << 6), shadow: &shadow)

        // pw_sdm (R18[3]); dither not disabled.
        let sdmFlag: UInt8 = (sdm == 0) ? 0x08 : 0x00
        try await writeRegisterMask(0x12, sdmFlag, mask: 0x18, shadow: &shadow)

        try await writeRegisterShadowed(0x16, UInt8(sdm >> 8), shadow: &shadow)
        try await writeRegisterShadowed(0x15, UInt8(sdm & 0xff), shadow: &shadow)

        // Check PLL lock (reg2 & 0x40); if it fails at min VCO current, bump to
        // max current (extra reg 0x12 write) and re-check, per the reference.
        var lockData = statusData
        for i in 0..<2 {
            lockData = try await readRegisters(count: 3)
            if (lockData[2] & 0x40) != 0 || vcoCurrMax == vcoCurrMin {
                break
            }
            if i == 0, lastVcoCurr != vcoCurrMax {
                try await writeRegisterMask(0x12, vcoCurrMax, mask: 0xe0, shadow: &shadow)
                lastVcoCurr = vcoCurrMax
            }
        }
        guard (lockData[2] & 0x40) != 0 else {
            throw SDRError.tuningOutOfRange(Frequency(hertz: loFreq))
        }

        // PLL autotune = 8 kHz (R26[3]).
        try await writeRegisterMask(0x1a, 0x08, mask: 0x08, shadow: &shadow)
    }

    // MARK: - Gain control

    /// The 29 exposed gain steps in tenths of a dB (`librtlsdr`'s `r82xx_gains`),
    /// the discrete LNA+mixer gains a caller may request. `setManualGain`
    /// derives the LNA/mixer register indices from the requested value via the
    /// ported step tables rather than indexing this list directly, so any value
    /// works; these are the reference-exposed steps.
    static let gainStepsTenthsDb: [Int] = [
        0, 9, 14, 27, 37, 77, 87, 125, 144, 157, 166, 197, 207, 229, 254,
        280, 297, 328, 338, 364, 372, 386, 402, 421, 434, 439, 445, 480, 496,
    ]

    /// LNA gain contributed by each LNA index (`r82xx_lna_gain_steps`), tenths
    /// of a dB. Index `i` holds the marginal gain added going from index `i-1`
    /// to `i` (index 0 = 0).
    private static let lnaGainSteps: [Int] = [
        0, 9, 13, 40, 38, 13, 31, 22, 26, 31, 26, 14, 19, 5, 35, 13,
    ]

    /// Mixer gain contributed by each mixer index (`r82xx_mixer_gain_steps`),
    /// tenths of a dB (marginal, as for `lnaGainSteps`).
    private static let mixerGainSteps: [Int] = [
        0, 5, 10, 10, 19, 9, 10, 25, 17, 10, 8, 16, 13, 6, 3, -8,
    ]

    /// VGA gain contributed by each VGA index (`r82xx_vga_gain_steps`), tenths
    /// of a dB (marginal). Used by `ifGainIndex` when mapping a non-zero IF-mode
    /// value to a VGA code; the golden gain path keeps IF-mode at 0 and never
    /// consults this table, but it is ported for fidelity.
    private static let vgaGainSteps: [Int] = [
        0, 26, 26, 30, 42, 35, 24, 13, 14, 32, 36, 34, 35, 37, 35, 36,
    ]

    /// VGA gain at index 0 (`VGA_BASE_GAIN`), tenths of a dB.
    private static let vgaBaseGain: Int = -47

    /// Default VGA code folded into reg 0x0c at init (`DEFAULT_IF_VGA_VAL`).
    private static let defaultIfVgaVal: Int = 11

    /// Ports `r82xx_get_rf_gain_index`: walks the LNA and mixer step tables in
    /// lock-step, accumulating gain until it reaches `gain` (tenths of a dB),
    /// and returns the resulting LNA and mixer register indices. Mirrors the
    /// reference's interleaving exactly (increment LNA, test, increment mixer,
    /// test), so it reproduces the captured indices for any requested gain.
    private static func rfGainIndex(tenthsDb gain: Int) -> (lna: Int, mixer: Int) {
        var totalGain = 0
        var lnaIndex = 0
        var mixerIndex = 0
        for _ in 0..<15 {
            if totalGain >= gain { break }
            lnaIndex += 1
            totalGain += lnaGainSteps[lnaIndex]
            if totalGain >= gain { break }
            mixerIndex += 1
            totalGain += mixerGainSteps[mixerIndex]
        }
        return (lnaIndex, mixerIndex)
    }

    /// Ports `r82xx_get_if_gain_index`: maps an IF gain (tenths of a dB) to a
    /// VGA register index by accumulating `vgaGainSteps` from `vgaBaseGain`.
    /// Faithfully reproduces the reference's double-increment loop (the inner
    /// `++vga_index` plus the `for`'s post-increment).
    private static func ifGainIndex(tenthsDb gain: Int) -> Int {
        var totalGain = vgaBaseGain
        var vgaIndex = 0
        while vgaIndex < 15 {
            if totalGain >= gain { break }
            vgaIndex += 1
            totalGain += vgaGainSteps[vgaIndex]
            vgaIndex += 1
        }
        return vgaIndex
    }

    /// Ports `r82xx_set_if_mode` (non-V4 path): maps `ifMode` to a VGA gain code
    /// and writes it into reg 0x0c[4:0] via the masked-write path. In the
    /// driver's supported state `ifMode` is always 0 (VGA code 0x10), but the
    /// full mapping is ported for fidelity.
    private func setIFMode(_ ifMode: Int, shadow: inout [UInt8]) async throws {
        let vgaGainIdx: Int
        if ifMode == 0 || ifMode == 10016 {
            vgaGainIdx = 0x10
        } else if ifMode >= -2500 && ifMode <= 2500 {
            vgaGainIdx = Self.ifGainIndex(tenthsDb: ifMode)
        } else if ifMode > 2500 && ifMode < 10000 {
            vgaGainIdx = Self.ifGainIndex(tenthsDb: ifMode - 5000)
        } else if ifMode >= 10000 && ifMode <= 10016 + 15 {
            vgaGainIdx = ifMode - 10000
        } else {
            vgaGainIdx = Self.defaultIfVgaVal
        }
        try await writeRegisterMask(0x0c, UInt8(vgaGainIdx), mask: 0x1f, shadow: &shadow)
    }

    /// Sets a fixed manual LNA+mixer gain, reproducing the reference
    /// `r82xx_set_gain(set_manual_gain = 1)` write sequence: disable LNA/mixer
    /// AGC, derive the LNA/mixer indices from `tenthsDb` via the ported step
    /// tables, program them, then set the VGA. Models a freshly-initialised
    /// tuner (the golden capture re-runs `r82xx_init` before each vector), so
    /// the masked writes RMW against `postInitShadow()`. The reference's dead
    /// 4-byte chip read (its result is unused) is performed for fidelity. All
    /// writes are bracketed by the I2C repeater, as the reference driver does.
    func setManualGain(tenthsDb: Int) async throws {
        var shadow = Self.postInitShadow()
        let (lnaIndex, mixerIndex) = Self.rfGainIndex(tenthsDb: tenthsDb)

        try await setRepeater(enabled: true)
        // LNA auto off == manual (R5[4] = 1).
        try await writeRegisterMask(0x05, 0x10, mask: 0x10, shadow: &shadow)
        // Mixer auto off == manual (R7[4] = 0).
        try await writeRegisterMask(0x07, 0x00, mask: 0x10, shadow: &shadow)
        // Reference reads regs 0x00..0x03 here; the result is discarded.
        _ = try await readRegisters(count: 4)
        // Set LNA index (R5[3:0]).
        try await writeRegisterMask(0x05, UInt8(lnaIndex), mask: 0x0f, shadow: &shadow)
        // Set mixer index (R7[3:0]).
        try await writeRegisterMask(0x07, UInt8(mixerIndex), mask: 0x0f, shadow: &shadow)
        // Set VGA (post-init IF-mode is 0 -> code 0x10).
        try await setIFMode(0, shadow: &shadow)
        try await setRepeater(enabled: false)
    }

    /// Enables LNA/mixer AGC, reproducing the reference
    /// `r82xx_set_gain(set_manual_gain = 0)` write sequence: turn LNA and mixer
    /// auto control on, then set the VGA. As with `setManualGain`, masked writes
    /// RMW against `postInitShadow()` and are bracketed by the I2C repeater.
    func setAutomaticGain() async throws {
        var shadow = Self.postInitShadow()

        try await setRepeater(enabled: true)
        // LNA auto on == AGC (R5[4] = 0).
        try await writeRegisterMask(0x05, 0x00, mask: 0x10, shadow: &shadow)
        // Mixer auto on == AGC (R7[4] = 1).
        try await writeRegisterMask(0x07, 0x10, mask: 0x10, shadow: &shadow)
        // Set VGA (post-init IF-mode is 0 -> code 0x10).
        try await setIFMode(0, shadow: &shadow)
        try await setRepeater(enabled: false)
    }

    /// Toggles the RTL2832U demodulator's I2C repeater bit, matching
    /// `rtlsdr_set_i2c_repeater`: `D(1, 0x01, 0x18, 1)` to enable,
    /// `D(1, 0x01, 0x10, 1)` to disable.
    private func setRepeater(enabled: Bool) async throws {
        try await rtl.demodWrite(page: 1, addr: 0x01, value: enabled ? 0x18 : 0x10, length: 1)
    }
}
