# CoreSDR — Design

**Date:** 2026-07-28
**Status:** Approved design, pre-implementation
**Repository:** CoreSDR (open-source Swift package). Sibling to the "Mac-first SDR" application, which lives in a separate repository and depends on this one.

## Purpose

CoreSDR is an open-source Swift package that lets macOS apps use Software Defined Radio hardware natively, with a clean async Swift API and **no third-party dependencies** — only Apple system frameworks. It reimplements the RTL-SDR (RTL2832U + R820T2) USB protocol directly on Apple's USB stack rather than linking `librtlsdr`/`libusb`.

```swift
let radio = try await SDRDevice.default
try await radio.tune(to: .mhz(173.225))
for try await block in radio.samples() {
    // block.raw is lossless interleaved IQ; block.normalized() is Float32
}
```

## Scope

**In scope (this package): hardware I/O only.**
- USB device discovery and connection.
- Tuning (center frequency), sample-rate selection, gain control.
- A live async stream of IQ sample blocks.
- Device capability reporting (frequency range, supported sample rates, gain steps).

**Out of scope (belongs to the consuming app):**
- DSP: FFT, decimation, filtering, power spectra.
- Signal detection, demodulation, decoding.
- SwiftUI views (SpectrumView / WaterfallView), recording UI, persistence.

**Explicit non-goals for v1:**
- Any device other than RTL-SDR (RTL2832U + R820T2). No Airspy/HackRF/SoapySDR. See "Future extension."
- Transmit. This is a receive-only design.

## Target hardware (v1)

NooElec NESDR SMArt: **RTL2832U** demodulator + **R820T2** tuner, USB ID `0x0bda:0x2838`. This is the best-documented RTL-SDR chipset/tuner combination. It presents as a vendor-specific USB device that no Apple kernel driver claims, so user-space USB access works with no DriverKit, kext, or elevated privileges. (A sandboxed Mac App Store consumer would add the `com.apple.security.device.usb` entitlement — the consuming app's concern, not CoreSDR's.)

## Architecture

Three layers. The lower boundary is a protocol seam that makes the entire driver testable without hardware.

```
┌─────────────────────────────────────────────┐
│ Public API   SDRDevice (actor), value types  │
├─────────────────────────────────────────────┤
│ Driver       RTLSDRDevice                     │
│              RTL2832U (registers, I²C to      │
│              tuner) + R820T2 (PLL, gains)      │
├─────────────────────────────────────────────┤
│ Transport    USBTransport (protocol)          │
│              IOUSBHostTransport (real HW)      │
└─────────────────────────────────────────────┘
```

### Transport layer

`USBTransport` is a small `Sendable` protocol with essentially three operations:

- **Control transfer (out):** write a register / send a vendor request.
- **Control transfer (in):** read a register.
- **Bulk stream:** deliver a continuous sequence of byte buffers from the IQ endpoint.

The concrete `IOUSBHostTransport` implements this using Apple's `IOUSBHost` framework (`IOUSBHostDevice`, `IOUSBHostInterface`, `IOUSBHostPipe`) — chosen over classic `IOKit`/`IOUSBLib` for a cleaner Swift surface. Sustained streaming (2.4 MS/s) requires **several bulk transfers kept in flight at once** (a ring of outstanding async reads), the same technique libusb uses; the transport owns this concern and exposes only a simple stream to the layer above.

`IOUSBHost`/USB interop is quarantined to this one concrete file. Everything above it depends only on the `USBTransport` protocol.

### Driver layer

`RTLSDRDevice` contains the interesting native protocol work, as pure logic over `USBTransport`:

- **RTL2832U control:** register banks (DEMOD / USB / SYS, plus the I²C bank used to reach the tuner), demod reset, buffer reset/enable, sample-rate resampler-ratio configuration, and frequency-correction (PPM) handling for the 0.5 ppm TCXO.
- **R820T2 tuner:** initialization register array, PLL programming (center-frequency → register values), and gain-stage tables (LNA / mixer / VGA) mapping requested dB to register settings, plus automatic gain.

Because this is all logic on top of `USBTransport`, it is exercised in tests against a mock that records/replays register traffic.

### Public API layer

`SDRDevice` is an `actor` that owns one `RTLSDRDevice` and presents the stable public surface. For v1 it talks to `RTLSDRDevice` directly (no intermediate backend protocol — that abstraction is deferred until a second real device exists; see "Future extension").

## Public API

```swift
public actor SDRDevice {
    public static func discover() async throws -> [SDRDeviceInfo]
    public static var `default`: SDRDevice { get async throws }   // first available device
    public init(_ info: SDRDeviceInfo) async throws

    public func tune(to frequency: Frequency) async throws
    public func setSampleRate(_ rate: SampleRate) async throws
    public func setGain(_ gain: Gain) async throws

    public nonisolated var capabilities: SDRCapabilities { get }
    public func samples() -> AsyncThrowingStream<IQBlock, Error>   // begins streaming
    public func stop() async
}

public struct SDRDeviceInfo: Sendable, Identifiable {
    public let id: String            // stable per physical device (USB location / serial)
    public let name: String          // e.g. "Realtek RTL2832U (R820T2)"
    public let serial: String?
}

public struct Frequency: Sendable, Comparable, Hashable {
    public let hertz: UInt64
    public static func hertz(_ v: UInt64) -> Frequency
    public static func khz(_ v: Double) -> Frequency
    public static func mhz(_ v: Double) -> Frequency
}

public struct SampleRate: Sendable, Comparable, Hashable {
    public let hertz: UInt32         // e.g. 2_400_000
}

public enum Gain: Sendable {
    case automatic
    case manual(dB: Float)           // snapped to nearest supported step
}

public struct SDRCapabilities: Sendable {
    public let frequencyRange: ClosedRange<Frequency>
    public let supportedSampleRates: [SampleRate]
    public let gainSteps: [Float]    // supported manual gains, dB
}

public struct IQBlock: Sendable {
    public let raw: [UInt8]          // interleaved unsigned 8-bit I,Q, as delivered (lossless)
    public let sampleRate: SampleRate
    public let centerFrequency: Frequency
    public let sequence: UInt64      // monotonic; gaps indicate dropped blocks
    public let hostTimestamp: UInt64 // mach_absolute_time at capture
    public func normalized() -> [Float]  // interleaved Float32 in [-1, 1], via vDSP, on demand
}

public enum SDRError: Error, Sendable {
    case deviceNotFound
    case unsupportedDevice
    case tuningOutOfRange(Frequency)
    case unsupportedSampleRate(SampleRate)
    case deviceDisconnected
    case notStreaming
    case usb(String)                 // underlying transport failure, described
}
```

### Design notes

- **Stream name is `samples()`, not `transmissions`.** "Transmissions" would imply signal detection, which is out of scope. The stream yields raw IQ blocks.
- **`IQBlock.raw` is the source of truth.** Raw unsigned 8-bit interleaved IQ is exactly what the hardware delivers — lossless, ideal for the app's IQ recording/export. `normalized()` converts to Float32 on demand (via vDSP), so CoreSDR stays true to "I/O only" and never forces a conversion cost a consumer might not want.
- **Backpressure = drop, don't lag.** SDR is real-time. If the consumer is slower than the sample rate, whole blocks are dropped rather than buffered unboundedly. `sequence` lets the consumer detect and quantify gaps.
- **Concurrency:** `SDRDevice` is an actor; the public surface is `Sendable` throughout and compiles under Swift 6 strict concurrency. `capabilities` is `nonisolated` (static per device).
- **Disconnection:** unplugging mid-stream finishes the stream by throwing `SDRError.deviceDisconnected`.

## Package layout

```
Package.swift                        // macOS 14+, swift-tools 6.0, strict concurrency
Sources/CoreSDR/
  SDRDevice.swift
  Frequency.swift  SampleRate.swift  Gain.swift
  IQBlock.swift    SDRCapabilities.swift  SDRDeviceInfo.swift  SDRError.swift
  Discovery.swift
  Driver/
    RTLSDRDevice.swift
    RTL2832U.swift                    // register defs + control logic
    R820T2.swift                      // tuner init, PLL math, gain tables
  Transport/
    USBTransport.swift                // protocol (the mock seam)
    IOUSBHostTransport.swift          // concrete, real hardware
Sources/coresdr-demo/                 // small CLI: list / tune / print live power
Tests/CoreSDRTests/                   // MockUSBTransport + pure-logic unit tests (no HW)
Tests/CoreSDRIntegrationTests/        // opt-in, hardware-gated via env var; excluded from CI
```

- **Deployment target: macOS 14+** for open-source reach (`IOUSBHost` is 10.15+); developed and tested on macOS 26.
- **`coresdr-demo`** is a thin executable target for validating against the real dongle without needing the app: list devices, tune, and print live signal power.

## Testing strategy

Test-driven throughout. Three tiers:

1. **Pure-logic unit tests (no hardware).** The majority of the driver:
   - R820T2 PLL: center-frequency → tuner register values.
   - Sample-rate → RTL2832U resampler-ratio register values.
   - Gain dB → register lookups (and nearest-step snapping).
   - Full init / tune / rate-change **register sequences** asserted against `MockUSBTransport`.
2. **Golden reference tests.** Assert our emitted register writes match the documented `librtlsdr` sequences for the same operations — high confidence achievable before hardware arrives.
3. **Hardware integration tests (opt-in, local only).** Open the real device, tune to a strong local FM station, assert non-zero IQ at expected power. Gated behind an environment variable; never run in CI.

`MockUSBTransport` is the linchpin: it records control transfers, lets tests assert exact register sequences, and can replay canned bulk data to exercise the streaming/`IQBlock` path deterministically.

## Error handling

- Typed `SDRError` at the public boundary; transport failures are wrapped as `.usb(String)`.
- Tuning/sample-rate requests outside `capabilities` throw before touching hardware.
- Mid-stream USB disconnection terminates `samples()` with `SDRError.deviceDisconnected`.
- `stop()` is idempotent; calling `samples()` after `stop()` starts a fresh stream.

## Future extension (deliberately deferred)

- **Second device (e.g. Airspy).** Airspy uses a different USB protocol and sample format; only the R820T2 tuner overlaps, and even that is driven differently. When a second real device exists, extract a `RadioBackend` protocol from the working `RTLSDRDevice` — a mechanical internal refactor informed by two real devices rather than one imagined one. The public API already hides RTL specifics, so no public change is required.
- **Additional RTL tuners** (e.g. R828D, FC0013) can be added behind the existing `RTLSDRDevice` without new public surface.
```
