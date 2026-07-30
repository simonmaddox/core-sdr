import IOKit

/// The stable public API surface for a single RTL-SDR dongle: an actor over
/// an injectable `USBTransport`, forwarding tune/rate/gain configuration to
/// an internal `RTLSDRDevice` and exposing IQ sample streaming.
///
/// Actor isolation alone is *not* enough to serialize the hardware-configuring
/// calls: `SDRDevice` is a reentrant actor, so `tune(to:)`/`setGain(_:)`/
/// `setSampleRate(_:)` from different tasks would interleave at their internal
/// `await`s — corrupting the R820T2's I2C-repeater bracketing and register
/// shadow. Those three calls are therefore funnelled through an explicit
/// in-actor serial queue (`serialized(_:)`), so exactly one runs against the
/// hardware at a time; the second waits for the first to finish rather than
/// racing it. (Streaming setup — `samples()`/`stop()` — is independent: it
/// touches the demodulator FIFO, not the tuner's repeater/shadow, so it is not
/// part of that queue.)
public actor SDRDevice {
    private let device: RTLSDRDevice
    private let info: SDRDeviceInfo
    private var streamTask: Task<Void, Never>?

    /// Tail of the hardware-operation serial queue. Each configuring call chains
    /// onto the previous one's completion (see `serialized(_:)`), so their USB
    /// register sequences never interleave. Starts already-completed.
    private var operationChain: Task<Void, Never> = Task {}

    /// Default bulk-transfer sizing for `samples()`: 16 KiB transfers, 4
    /// in flight, matching common `librtlsdr`-style client defaults.
    private static let defaultTransferSize = 16384
    private static let defaultInFlight = 4

    /// Test/discovery seam: construct directly over any `USBTransport` and
    /// descriptive `info`. `public static discover()`/`default` (added in a
    /// later task) call this with the real IOUSBLib-backed transport.
    init(transport: any USBTransport, info: SDRDeviceInfo) {
        self.device = RTLSDRDevice(transport: transport)
        self.info = info
    }

    /// Powers on and configures the demodulator and tuner. Forwards to
    /// `RTLSDRDevice.open()`; called by `discover()`/`default` (later task)
    /// after constructing the device.
    func open() async throws {
        try await device.open()
    }

    /// Capability envelope (tunable frequency range, supported sample
    /// rates, gain steps) for the RTL2832U + R820T2 combination. This is
    /// device-independent (backed by a `static let` on `RTLSDRDevice`), so
    /// it's exposed `nonisolated` and safe to read without awaiting the
    /// actor.
    public nonisolated var capabilities: SDRCapabilities {
        RTLSDRDevice.capabilities
    }

    /// Tunes the R820T2 PLL to `frequency`. Throws `SDRError.tuningOutOfRange`
    /// if `frequency` falls outside `capabilities.frequencyRange`.
    public func tune(to frequency: Frequency) async throws {
        try await serialized { [device] in try await device.tune(to: frequency) }
    }

    /// Configures the demodulator resampler for `rate`.
    public func setSampleRate(_ rate: SampleRate) async throws {
        try await serialized { [device] in try await device.setSampleRate(rate) }
    }

    /// Sets automatic (AGC) or manual gain.
    public func setGain(_ gain: Gain) async throws {
        try await serialized { [device] in try await device.setGain(gain) }
    }

    /// Runs `operation` after every previously-enqueued hardware operation has
    /// finished, so the tuner's read-modify-write register sequences never
    /// interleave under actor reentrancy. `operation` runs off the actor (it
    /// only touches the `Sendable` `RTLSDRDevice` value), so awaiting it here
    /// never blocks the next caller from enqueuing.
    private func serialized<T: Sendable>(
        _ operation: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        let previous = operationChain
        let operationTask = Task { () async throws -> T in
            await previous.value
            return try await operation()
        }
        // Publish this operation as the new tail *before* suspending, so a
        // concurrent caller chains behind it. A failing operation must not break
        // the chain, so the tail tracker swallows the error.
        operationChain = Task { _ = try? await operationTask.value }
        return try await operationTask.value
    }

    /// Starts streaming IQ samples and returns the stream. Cancels any
    /// previously active stream first, so calling `samples()` again (with
    /// or without an intervening `stop()`) always starts a fresh one.
    ///
    /// Uses sensible defaults for the underlying bulk transfer sizing
    /// (16384-byte transfers, 4 in flight). The active pump task is
    /// tracked so `stop()` can cancel it.
    ///
    /// A single pump drives the transport's bulk stream directly and stamps each
    /// transfer into an `IQBlock` — the intermediate per-`RTLSDRDevice` stream is
    /// gone, so a transfer crosses two `AsyncThrowingStream`s (bounded transport
    /// ring → this `bufferingNewest(16)` stream) rather than three. The 16-deep
    /// buffer (~55 ms at 2.4 MS/s) absorbs the bursts the `inFlight` USB
    /// transfers complete in — with a 1-deep buffer even a tight consumer lost
    /// ~1% of blocks to burst overwrites, which audio consumers hear as
    /// crackle. Sustained-overload behaviour is unchanged: latest wins, oldest
    /// buffered block is dropped first, and `IQBlock.sequence` still exposes
    /// every gap. Deterministic
    /// restart ordering on the shared USB pipe is handled inside the transport,
    /// so back-to-back `stop()` + `samples()` (or `samples()` + `samples()`)
    /// cannot have the old ring's teardown starve the new one.
    public func samples() -> AsyncThrowingStream<IQBlock, Error> {
        streamTask?.cancel()

        let (stream, continuation) = AsyncThrowingStream<IQBlock, Error>.makeStream(
            bufferingPolicy: .bufferingNewest(16)
        )
        let device = self.device
        let task = Task {
            do {
                try await device.resetStreaming()
                var sequence: UInt64 = 0
                for try await chunk in device.bulkStream(
                    transferSize: Self.defaultTransferSize,
                    inFlight: Self.defaultInFlight
                ) {
                    continuation.yield(device.makeBlock(raw: chunk, sequence: sequence))
                    sequence += 1
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in
            task.cancel()
        }
        streamTask = task
        return stream
    }

    /// Cancels the active streaming task started by `samples()`, if any.
    /// A subsequent call to `samples()` starts a fresh stream.
    public func stop() async {
        streamTask?.cancel()
        streamTask = nil
    }
}

// MARK: - Public discovery / factories

extension SDRDevice {
    /// Enumerates attached RTL-SDR dongles without opening any of them.
    ///
    /// Wraps `IOUSBLibTransport.discover()`, keeping only the descriptive
    /// `SDRDeviceInfo` for each match and releasing the `io_service_t` handles
    /// (which `discover()` transfers to us) so none leak.
    public static func discover() async throws -> [SDRDeviceInfo] {
        let matches = try IOUSBLibTransport.discover()
        defer { for match in matches { IOObjectRelease(match.service) } }
        return matches.map(\.info)
    }

    /// Opens the first discovered dongle and returns a ready-to-use device.
    ///
    /// Throws `SDRError.deviceNotFound` if no dongle is attached. The
    /// non-selected service handles are released; the selected one is released
    /// after building the transport (which retains its own reference).
    public static var `default`: SDRDevice {
        get async throws {
            let matches = try IOUSBLibTransport.discover()
            defer { for match in matches { IOObjectRelease(match.service) } }
            guard let selected = matches.first else {
                throw SDRError.deviceNotFound
            }
            let transport = try IOUSBLibTransport(service: selected.service)
            let device = SDRDevice(transport: transport, info: selected.info)
            try await device.open()
            return device
        }
    }

    /// Re-discovers the attached dongles, matches `info.id`, and opens that one.
    ///
    /// An actor async convenience `init` is awkward, so this static factory is
    /// used instead. Throws `SDRError.deviceNotFound` if the id is no longer
    /// present. All service handles are released once the transport is built.
    public static func open(_ info: SDRDeviceInfo) async throws -> SDRDevice {
        let matches = try IOUSBLibTransport.discover()
        defer { for match in matches { IOObjectRelease(match.service) } }
        guard let selected = matches.first(where: { $0.info.id == info.id }) else {
            throw SDRError.deviceNotFound
        }
        let transport = try IOUSBLibTransport(service: selected.service)
        let device = SDRDevice(transport: transport, info: selected.info)
        try await device.open()
        return device
    }
}
