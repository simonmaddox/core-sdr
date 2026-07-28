import IOKit

/// The stable public API surface for a single RTL-SDR dongle: an actor over
/// an injectable `USBTransport`, forwarding tune/rate/gain configuration to
/// an internal `RTLSDRDevice` and exposing IQ sample streaming.
///
/// Actor isolation gives callers a single, serialized entry point per
/// device: concurrent `tune(to:)`/`setGain(_:)`/`samples()` calls from
/// multiple tasks are queued rather than racing on the underlying USB
/// transport.
public actor SDRDevice {
    private let device: RTLSDRDevice
    private let info: SDRDeviceInfo
    private var streamTask: Task<Void, Never>?

    /// Default bulk-transfer sizing for `samples()`: 16 KiB transfers, 4
    /// in flight, matching common `librtlsdr`-style client defaults.
    private static let defaultTransferSize = 16384
    private static let defaultInFlight = 4

    /// Test/discovery seam: construct directly over any `USBTransport` and
    /// descriptive `info`. `public static discover()`/`default` (added in a
    /// later task) call this with the real IOUSBHost-backed transport.
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
        try await device.tune(to: frequency)
    }

    /// Configures the demodulator resampler for `rate`.
    public func setSampleRate(_ rate: SampleRate) async throws {
        try await device.setSampleRate(rate)
    }

    /// Sets automatic (AGC) or manual gain.
    public func setGain(_ gain: Gain) async throws {
        try await device.setGain(gain)
    }

    /// Starts streaming IQ samples and returns the stream. Cancels any
    /// previously active stream first, so calling `samples()` again (with
    /// or without an intervening `stop()`) always starts a fresh one.
    ///
    /// Uses sensible defaults for the underlying bulk transfer sizing
    /// (16384-byte transfers, 4 in flight). The active pump task is
    /// tracked so `stop()` can cancel it.
    public func samples() -> AsyncThrowingStream<IQBlock, Error> {
        streamTask?.cancel()

        let (stream, continuation) = AsyncThrowingStream<IQBlock, Error>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let device = self.device
        let task = Task {
            do {
                for try await block in device.samples(
                    transferSize: Self.defaultTransferSize,
                    inFlight: Self.defaultInFlight
                ) {
                    continuation.yield(block)
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
    /// Wraps `IOUSBHostTransport.discover()`, keeping only the descriptive
    /// `SDRDeviceInfo` for each match and releasing the `io_service_t` handles
    /// (which `discover()` transfers to us) so none leak.
    public static func discover() async throws -> [SDRDeviceInfo] {
        let matches = try IOUSBHostTransport.discover()
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
            let matches = try IOUSBHostTransport.discover()
            defer { for match in matches { IOObjectRelease(match.service) } }
            guard let selected = matches.first else {
                throw SDRError.deviceNotFound
            }
            let transport = try IOUSBHostTransport(service: selected.service)
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
        let matches = try IOUSBHostTransport.discover()
        defer { for match in matches { IOObjectRelease(match.service) } }
        guard let selected = matches.first(where: { $0.info.id == info.id }) else {
            throw SDRError.deviceNotFound
        }
        let transport = try IOUSBHostTransport(service: selected.service)
        let device = SDRDevice(transport: transport, info: selected.info)
        try await device.open()
        return device
    }
}
