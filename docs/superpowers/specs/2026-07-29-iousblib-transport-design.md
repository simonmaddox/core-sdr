# CoreSDR 1.1 — IOUSBLib Transport (macOS App Sandbox / MAS eligibility)

**Date:** 2026-07-29
**Status:** Approved design, pre-implementation
**Repository:** CoreSDR (`simonmaddox/core-sdr`). Target release: **1.1.0**.

## Purpose

Replace CoreSDR's macOS USB transport — currently built on **`IOUSBHost.framework`** — with the classic **`IOUSBLib`** (`IOUSBDeviceInterface` / `IOUSBInterfaceInterface`) API, so that a **sandboxed** consuming app can access the RTL-SDR with only the standard `com.apple.security.device.usb` entitlement, making it **Mac App Store-eligible**.

### Why (the rationale, also documented in the README)

Under the macOS App Sandbox, `com.apple.security.device.usb` whitelists opening the **legacy** IOKit USB user-client classes (`IOUSBDeviceUserClientV2`, `IOUSBInterfaceUserClientV3`) — the ones `IOUSBLib` opens. It does **not** cover `IOUSBHost.framework`'s user-client classes (`AppleUSBHostFrameworkDeviceClient` / `…InterfaceClient`). So an IOUSBHost-based transport requires a `com.apple.security.temporary-exception.iokit-user-client-class` entitlement, which is **not accepted on the Mac App Store**.

This was verified empirically (a sandboxed, signed test app with only `com.apple.security.device.usb` opened the RTL-SDR via `IOUSBLib`'s `USBDeviceOpen` → `kIOReturnSuccess`; the same app **without** that entitlement was denied at `IOCreatePlugInInterfaceForService`). `IOUSBLib` also works non-sandboxed and works everywhere IOUSBHost does — it is a strict superset for this use case — so CoreSDR uses **IOUSBLib only**; no runtime transport selection is needed.

## Scope

**In scope:**
- A new `IOUSBLibTransport` conforming to the existing internal `USBTransport` protocol (`controlWrite`, `controlRead`, `bulkStream`).
- Device + interface-0 open via the classic plug-in interface.
- Control transfers via `IOUSBDeviceInterface.DeviceRequest`.
- Continuous bulk-IN streaming via `IOUSBInterfaceInterface.ReadPipeAsync` with a CFRunLoop async event source on a dedicated thread, keeping `inFlight` reads outstanding (a ring), and clean teardown on cancellation.
- Discovery matching the legacy `IOUSBDevice` service class for VID/PID `0x0bda:0x2838`, returning `SDRDeviceInfo` (stable id, name, serial) — the public `SDRDevice.discover()`/`default`/`open(_:)` wire to this transport.
- Delete `IOUSBHostTransport.swift`.
- README "Why IOUSBLib" section.
- Version bump to 1.1.0 and release.

**Out of scope (unchanged):**
- The `USBTransport` protocol itself and everything above it: `RTL2832U` / `R820T2` drivers, register protocol, tuner PLL/gain, `RTLSDRDevice`, the public `SDRDevice` actor, `IQBlock`, value types, and the entire mock-based test suite (36 tests) — all transport-agnostic, all unchanged.
- No dual-transport / runtime selection (IOUSBLib-only, per decision).
- No public API changes. Consuming apps see the same `SDRDevice` API; the only observable difference is that a sandboxed app now needs only `com.apple.security.device.usb` (and can drop the temporary-exception).

## Architecture

The three-layer architecture is unchanged; only the concrete transport at the bottom changes.

```
Public API   SDRDevice (actor), value types            ← unchanged
Driver       RTLSDRDevice, RTL2832U + R820T2            ← unchanged (mock-tested)
Transport    USBTransport (protocol)                    ← unchanged seam
             IOUSBLibTransport (real HW)  ← NEW (replaces IOUSBHostTransport)
```

### `IOUSBLibTransport`

- **Open (`init(service:)`):** `IOCreatePlugInInterfaceForService(service, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID, …)` → `QueryInterface(kIOUSBDeviceInterfaceID*)` → `USBDeviceOpen`. Then find interface 0: `CreateInterfaceIterator` (with an all-match request) → for interface 0's service, `IOCreatePlugInInterfaceForService(…, kIOUSBInterfaceUserClientTypeID, …)` → `QueryInterface(kIOUSBInterfaceInterfaceID*)` → `USBInterfaceOpen`. Map failures to `SDRError.usb(String)`. Quarantine all IOKit/`IOUSBLib` interop to this one file (COM-style function-pointer calls: `(*iface)->Method(iface, …)`).
- **`controlWrite`/`controlRead`:** build an `IOUSBDevRequest` from `USBControlRequest` (`bmRequestType`/`bRequest`/`wValue`/`wIndex`/`wLenDone`, `pData`) and call `(*device)->DeviceRequest(device, &req)`. Bridge the synchronous call into `async`. Reads truncate to `wLenDone`.
- **`bulkStream(endpoint:transferSize:inFlight:)`:** locate the bulk-IN pipe index for endpoint `0x81` (`GetNumEndpoints` + `GetPipeProperties`). Create the interface's async event source (`CreateInterfaceAsyncEventSource`) and run it on a **dedicated thread**'s CFRunLoop. Submit `inFlight` `ReadPipeAsync(pipeRef, buffer, transferSize, callback, refcon)` requests; each completion yields its bytes to the `AsyncThrowingStream` and re-submits (a ring). On termination/cancellation (`onTermination`), `AbortPipe` + stop the run loop + release. Device-removal errors surface as `SDRError.deviceDisconnected`. Protect the ring/stopped state with a lock (matching the IOUSBHost transport's care). This is the classic libusb macOS pattern; hold the same "no submit after abort" discipline the IOUSBHost transport used (make check-and-submit atomic with flip-and-abort).

### Discovery

`USBDeviceMatching` matches the **legacy** service class: `IOServiceMatching(kIOUSBDeviceClassName)` (i.e. `"IOUSBDevice"`) with `idVendor`/`idProduct` = `0x0bda`/`0x2838`, via `IOServiceGetMatchingServices`. (IOUSBHost matched `"IOUSBHostDevice"`; the legacy transport needs the `IOUSBDevice` service to create the `IOUSBDeviceInterface`.) `IOUSBLibTransport.discover()` returns `[(info: SDRDeviceInfo, service: io_service_t)]` with a stable id (`IORegistryEntryGetRegistryEntryID`), a human name, and the USB serial string. IOKit reference discipline as before (iterator released; matching dict consumed once; non-selected services released; the returned service handed to `init(service:)`).

## Testing

- **Unchanged:** the driver + tuner logic and golden-vector tests run against `MockUSBTransport` — 36 tests, no hardware — and must stay green (they don't touch the transport implementation).
- **Live (opt-in / manual):** the new transport is hardware-validated against the NESDR: a control round-trip (write + read back a known register, e.g. the baseband FIR bytes), a brief bulk-IN capture (non-empty IQ blocks at the expected size with clean teardown), and a full `discover → open → tune → stream` end-to-end. The existing hardware-gated integration test (`CoreSDRIntegrationTests`) exercises the public API and now runs over `IOUSBLibTransport`.
- **The transport's IOKit calls can't be unit-tested** (same as IOUSBHost was) — correctness is established by careful implementation + live validation, mirroring how the original transport was built.

## Error handling

Same public contract: `SDRError.usb(String)` for transport failures, `SDRError.deviceDisconnected` on device removal mid-stream, clean stream teardown on cancellation. No change to `SDRError` or the public surface.

## README changes

Add a **"Why IOUSBLib (and the App Sandbox)"** section explaining: the sandbox covers legacy IOKit USB user clients under `com.apple.security.device.usb` but not IOUSBHost's; therefore CoreSDR uses IOUSBLib so that sandboxed apps (incl. Mac App Store apps) can access the device with just `com.apple.security.device.usb` and no temporary-exception. Note IOUSBLib is deprecated-but-supported (as libusb uses it) and that the `USBTransport` seam keeps an IOUSBHost transport re-addable later if a device ever needs it. Update any transport-specific wording elsewhere in the README.

## Release

Bump the package/version references to **1.1.0**, tag `1.1.0`, and cut a GitHub release. Consuming apps (e.g. Spectrum) can then depend on `from: "1.1.0"` and drop the `temporary-exception.iokit-user-client-class` entitlement.
