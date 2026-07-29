# CoreSDR

A native, dependency-free Swift package for using RTL-SDR software-defined
radio dongles on macOS.

CoreSDR talks to the hardware directly through Apple's `IOUSBLib`, using only
Apple system frameworks. It implements the RTL2832U + R820T2 USB protocol in
Swift, from control transfers up through a live, backpressure-aware IQ sample
stream.

CoreSDR is **hardware I/O only**: device discovery, tuning, gain, sample
rate, and a stream of raw IQ blocks. DSP (FFT, filtering, demodulation) and
UI belong in the app built on top of it.

```swift
import CoreSDR

let radio = try await SDRDevice.default
try await radio.tune(to: .mhz(104.9))
try await radio.setSampleRate(.rate2_4M)
try await radio.setGain(.automatic)

for try await block in await radio.samples() {
    let iq = block.normalized()   // interleaved Float32 [I, Q, I, Q, …] in [-1, 1]
    // ... your DSP goes here ...
}
```

## Requirements

- macOS 14+
- Swift 6

## Installation

Add CoreSDR via Swift Package Manager:

```swift
dependencies: [
    .package(url: "https://github.com/simonmaddox/core-sdr.git", from: "1.1.0"),
]
```

Then add `"CoreSDR"` to your target's dependencies.

## Quick start

Discover attached dongles:

```swift
import CoreSDR

let devices = try await SDRDevice.discover()
for device in devices {
    print(device.id, device.name, device.serial ?? "(no serial)")
}
```

Open the first available device, tune it, and stream IQ samples:

```swift
import CoreSDR

let radio = try await SDRDevice.default   // opens the first discovered device
try await radio.tune(to: .mhz(104.9))
try await radio.setSampleRate(.rate2_4M)
try await radio.setGain(.automatic)       // or .manual(dB: 20)

for try await block in await radio.samples() {
    // block.raw is the lossless interleaved unsigned-8-bit IQ exactly as
    // delivered by the hardware — ideal for recording/export.
    let iq = block.normalized()           // Float32, [-1, 1], via vDSP

    // ... FFT, power spectrum, demodulation, whatever your app needs ...
}

await radio.stop()
```

`SDRDevice` is a Swift actor, so `tune(to:)`, `setSampleRate(_:)`,
`setGain(_:)`, and `samples()` are all `async`. Reopen a specific device
later (by its stable `SDRDeviceInfo.id`) with `SDRDevice.open(_:)`.

The stream drops whole blocks rather than buffering unboundedly if your
consumer falls behind — SDR is real-time, and `IQBlock.sequence` is
monotonic so you can detect gaps. Unplugging the dongle mid-stream finishes
the stream by throwing `SDRError.deviceDisconnected`.

## Supported hardware

RTL2832U demodulator + R820T2 tuner, USB ID `0x0bda:0x2838` — e.g. the
Nooelec NESDR SMArt or RTL-SDR Blog dongles. This is the best-documented
RTL-SDR chipset/tuner combination, and it's what CoreSDR has been validated
against on real hardware (receiving live FM broadcast).

The device presents as a vendor-specific USB device with no Apple kernel
driver claiming it, so user-space access works with no DriverKit, kext, or
elevated privileges required.

## Why IOUSBLib (and the App Sandbox)

CoreSDR itself requires no entitlement. If you ship a sandboxed app that links
CoreSDR, including a Mac App Store app, add the USB entitlement to *your app*:

```xml
<key>com.apple.security.device.usb</key>
<true/>
```

That single entitlement is all you need, and the choice of USB stack is what
makes that possible.

`com.apple.security.device.usb` grants a sandboxed app access to the legacy
IOKit USB user clients (`IOUSBDeviceUserClientV2` and
`IOUSBInterfaceUserClientV3`), which are exactly the clients `IOUSBLib` opens.
It does *not* cover `IOUSBHost.framework`'s user clients
(`AppleUSBHostFrameworkDeviceClient` and its interface client). Reaching those
from a sandbox requires a
`com.apple.security.temporary-exception.iokit-user-client-class` entitlement,
and the Mac App Store does not accept temporary-exception entitlements. So an
`IOUSBHost`-based transport cannot ship on the Mac App Store with only the
public USB entitlement.

CoreSDR therefore uses `IOUSBLib`. A sandboxed app, Mac App Store included,
reaches the RTL-SDR with just `com.apple.security.device.usb` and no
temporary-exception. This was verified empirically: a signed, sandboxed app
carrying only `device.usb` opened the dongle through CoreSDR, and removing the
entitlement caused the open to be denied.

`IOUSBLib` is a deprecated-but-supported IOKit API (it's the same USB path
libusb uses on macOS). It works both sandboxed and non-sandboxed, and the
internal `USBTransport` seam keeps an `IOUSBHost` transport re-addable later if
a future device ever needs it.

## `coresdr-demo`

A small CLI included in this package for validating against real hardware
without writing any code:

```console
$ swift run coresdr-demo
Discovered 1 device(s):
  id:     ...
  name:   Realtek RTL2832U (R820T2)
  serial: (none)

$ swift run coresdr-demo --tune 104.9
Opening default device...
Tuning to 104.900 MHz, 2.4 MS/s, automatic gain...
Streaming for ~1 second...
Blocks: 73   Power (mean IQ magnitude): 0.2134
  [############]
```

## Testing

```console
$ swift test
```

runs the full unit suite — pure-logic tests (register sequences, PLL math,
gain tables, sample-rate configuration) plus golden-reference tests against
documented `librtlsdr` register sequences, all against a mock USB transport.
No hardware required, and this is what runs in CI.

A separate, hardware-gated live-capture test opens a real dongle, tunes to a
broadcast station, and asserts non-zero signal power. It's excluded from the
default run and only executes with a dongle connected and an explicit
opt-in:

```console
$ CORESDR_HW_TEST=1 CORESDR_HW_FREQ_MHZ=104.9 swift test --filter HardwareTests
```

## Scope and non-goals

CoreSDR is receive-only — there is no transmit support, and none is planned.

For v1, it supports RTL-SDR (RTL2832U + R820T2) only. The public `SDRDevice`
API is already device-agnostic (it doesn't expose anything RTL-specific), so
when a second real device exists (e.g. Airspy), a `RadioBackend` protocol
will be extracted from the working `RTLSDRDevice` implementation — a
mechanical internal refactor, not a public API change.

DSP — FFT, decimation, filtering, demodulation, spectra — and UI (spectrum
views, waterfalls, recording) are deliberately out of scope: they belong in
the app built on top of CoreSDR.

## License

CoreSDR is released under the MIT License. See [LICENSE](LICENSE).
