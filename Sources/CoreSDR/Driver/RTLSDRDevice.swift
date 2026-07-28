import Foundation

/// Thread-safe storage for the device's current tuning state (center
/// frequency, sample rate), so `RTLSDRDevice` (a `let`-held value type) can
/// still track live state set by `tune(to:)`/`setSampleRate(_:)` for
/// `samples(...)` to stamp onto each `IQBlock`.
///
/// `@unchecked Sendable` because the compiler can't verify the manual
/// locking discipline; all access goes through `withLock`.
private final class TuningState: @unchecked Sendable {
    private let lock = NSLock()
    private var _centerFrequency = Frequency(hertz: 0)
    private var _sampleRate = SampleRate.rate2_048M

    var centerFrequency: Frequency {
        get { lock.withLock { _centerFrequency } }
        set { lock.withLock { _centerFrequency = newValue } }
    }

    var sampleRate: SampleRate {
        get { lock.withLock { _sampleRate } }
        set { lock.withLock { _sampleRate = newValue } }
    }
}

/// Top-level orchestration for an RTL-SDR (RTL2832U + R820T2) dongle: owns
/// the baseband and tuner drivers, opens the device, and exposes tune /
/// sample-rate / gain with capability range-checks against `capabilities`.
struct RTLSDRDevice {
    private let rtl: RTL2832U
    private let tuner: R820T2
    private let tuningState = TuningState()

    /// Capability envelope for the RTL2832U + R820T2 combination: R820T2's
    /// tunable RF range, the two demodulator sample rates this driver
    /// programs, and the tuner's exposed gain steps (converted from tenths
    /// of a dB to dB).
    static let capabilities = SDRCapabilities(
        frequencyRange: Frequency.mhz(24)...Frequency.mhz(1766),
        supportedSampleRates: [.rate2_048M, .rate2_4M],
        gainSteps: R820T2.gainStepsTenthsDb.map { Float($0) / 10 }
    )

    init(transport: any USBTransport) {
        self.rtl = RTL2832U(transport: transport)
        self.tuner = R820T2(rtl: rtl)
    }

    /// Powers on and configures the demodulator, then initializes the tuner.
    /// Order matters: the tuner's I2C bus is only reachable via the
    /// demodulator, so baseband init must complete first.
    func open() async throws {
        try await rtl.initBaseband()
        try await tuner.initialize()
        // The R820T2 delivers a 3.57 MHz low-IF; switch the demod out of the
        // zero-IF config `initBaseband` leaves it in and program the digital
        // downconverter so the wanted signal lands in the sampled passband.
        try await rtl.configureForR820T2()
        // Program the default resampler rate so a consumer that calls
        // tune()/samples() without ever calling setSampleRate(_:) still gets
        // a genuinely-configured demod and truthful IQBlock.sampleRate
        // stamps (TuningState otherwise merely *defaults* to this rate
        // without the registers being written).
        try await setSampleRate(.rate2_048M)
    }

    /// Tunes the R820T2 PLL to `freq`, after checking it against
    /// `capabilities.frequencyRange`.
    func tune(to freq: Frequency) async throws {
        guard Self.capabilities.frequencyRange.contains(freq) else {
            throw SDRError.tuningOutOfRange(freq)
        }
        try await tuner.setFrequency(freq.hertz)
        tuningState.centerFrequency = freq
    }

    /// Configures the demodulator resampler for `rate`.
    func setSampleRate(_ rate: SampleRate) async throws {
        try await rtl.setSampleRate(rate)
        tuningState.sampleRate = rate
    }

    /// Sets automatic (AGC) or manual gain. Manual gain is snapped to the
    /// nearest step in `capabilities.gainSteps` before being sent to the
    /// tuner in tenths of a dB.
    func setGain(_ gain: Gain) async throws {
        switch gain {
        case .automatic:
            try await tuner.setAutomaticGain()
        case .manual(let dB):
            let step = Self.capabilities.nearestGainStep(to: dB)
            try await tuner.setManualGain(tenthsDb: Int((step * 10).rounded()))
        }
    }
}

extension RTLSDRDevice {
    /// Streams live IQ samples from the dongle's bulk endpoint (0x81).
    ///
    /// Resets the USB buffer, then bridges `transport.bulkStream` into
    /// `IQBlock`s stamped with the current `centerFrequency`/`sampleRate`
    /// (as last set by `tune(to:)`/`setSampleRate(_:)`), a monotonic
    /// per-transfer `sequence` (so dropped/gapped transfers are observable),
    /// and a `mach_absolute_time()` host timestamp.
    ///
    /// Backpressure is drop-on-slow: the returned stream is built with
    /// `.bufferingNewest(1)`, so a consumer that falls behind live RF drops
    /// whole blocks (keeping only the newest) rather than accumulating lag.
    ///
    /// Cancelling the consuming task, or otherwise terminating iteration,
    /// stops the underlying bulk transfer stream.
    func samples(transferSize: Int, inFlight: Int) -> AsyncThrowingStream<IQBlock, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let pump = Task {
                do {
                    try await rtl.resetBuffer()
                    var sequence: UInt64 = 0
                    let upstream = rtl.transport.bulkStream(
                        endpoint: 0x81,
                        transferSize: transferSize,
                        inFlight: inFlight
                    )
                    for try await chunk in upstream {
                        let block = IQBlock(
                            raw: chunk,
                            sampleRate: tuningState.sampleRate,
                            centerFrequency: tuningState.centerFrequency,
                            sequence: sequence,
                            hostTimestamp: mach_absolute_time()
                        )
                        sequence += 1
                        continuation.yield(block)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                pump.cancel()
            }
        }
    }
}
