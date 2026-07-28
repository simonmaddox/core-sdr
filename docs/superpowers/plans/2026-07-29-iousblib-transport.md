# CoreSDR IOUSBLib Transport Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace CoreSDR's macOS USB transport (IOUSBHost) with legacy `IOUSBLib`, so a sandboxed app gets USB access with only `com.apple.security.device.usb` (Mac App Store-eligible, no temporary-exception). Release 1.1.0.

**Architecture:** A new `IOUSBLibTransport` conforms to the existing internal `USBTransport` protocol (`controlWrite`/`controlRead`/`bulkStream`). Everything above the seam — `RTL2832U`/`R820T2` drivers, `RTLSDRDevice`, the public `SDRDevice` actor, value types, and the 36-test mock suite — is transport-agnostic and unchanged. Only the concrete transport + its discovery matching change; `IOUSBHostTransport` is deleted.

**Tech Stack:** Swift 6, `IOKit`/`IOKit.usb` (`IOUSBLib`: `IOUSBDeviceInterface`/`IOUSBInterfaceInterface`), `IOCFPlugInInterface`, CFRunLoop async event source. No third-party dependencies.

## Global Constraints

- **No third-party dependencies** — Apple system frameworks only. **IOUSBLib-only** (no dual transport / runtime selection).
- **Do not change the `USBTransport` protocol or anything above it.** The driver/tuner/value-type layers and all mock-based tests stay byte-for-byte and MUST remain green (`swift test` → the existing 36 tests, no hardware).
- macOS 14+ deployment target, Swift 6 language mode, zero build warnings.
- **Quarantine all IOKit/IOUSBLib COM interop to the transport file(s).** COM calls are `(*iface)->Method(iface, args…)`.
- **Live-validate each transport task against the connected NESDR** (VID `0x0bda`/PID `0x2838`, serial `63280580`). Free the device first each time: `pkill -9 -x coresdr-demo 2>/dev/null` (no app holds it here; the CLI is the test vehicle).
- Commit after each green step; **no `Co-Authored-By` trailer**.

## Key references (read these; they save you)

- **Proven IOUSBLib open + discovery code:** `/private/tmp/claude-501/-Users-simon-Development-core-sdr/5f8065fc-ba89-4423-8452-a5f9839c5de1/scratchpad/mas-spike/usbspike.c` — a working C program that matches `IOUSBDevice` by VID/PID, creates the `IOUSBDeviceInterface` via `IOCreatePlugInInterfaceForService(… kIOUSBDeviceUserClientTypeID …)`, and calls `USBDeviceOpen` successfully (sandboxed, with only `device.usb`). Mirror its open/matching sequence.
- **Structural reference (same `USBTransport` contract, ring discipline, IOKit ref management, discovery→SDRDeviceInfo):** the existing `Sources/CoreSDR/Transport/IOUSBHostTransport.swift` — same public shape and the TOCTOU-safe "no submit after abort" bulk discipline to replicate; only the underlying API changes.
- **The seam:** `Sources/CoreSDR/Transport/USBTransport.swift` (`USBControlRequest`, `protocol USBTransport`). **The i2c/register encoding** for the control round-trip test lives in `Sources/CoreSDR/Driver/RTLRegisters.swift` + `RTL2832U.swift`.

---

## Task 1: `IOUSBLibTransport` — discovery + device/interface open

**Files:**
- Create: `Sources/CoreSDR/Transport/IOUSBLibTransport.swift`
- Modify: `Sources/CoreSDR/Transport/USBDeviceMatching.swift` (match the legacy `IOUSBDevice` class)

**Interfaces:**
- Produces:
```swift
final class IOUSBLibTransport: USBTransport, @unchecked Sendable {
    static func discover() throws -> [(info: SDRDeviceInfo, service: io_service_t)]
    init(service: io_service_t) throws   // opens IOUSBDeviceInterface + interface 0 (IOUSBInterfaceInterface)
    // USBTransport methods stubbed here (Tasks 2-3 fill them): throw SDRError.usb("not implemented") + TODO.
}
```
- `USBDeviceMatching`: keep `rtlVendorID = 0x0bda`, `rtlProductID = 0x2838`; change the matching class from `"IOUSBHostDevice"` to the legacy **`"IOUSBDevice"`** (`kIOUSBDeviceClassName`) so the `IOUSBDeviceInterface` plug-in can be created from the matched service.

- [ ] **Step 1: Update `USBDeviceMatching`** to match `IOServiceMatching("IOUSBDevice")` with `"idVendor"`/`"idProduct"` = 0x0bda/0x2838 (string keys, as before).
- [ ] **Step 2: Implement `discover()`** — enumerate matches, build `SDRDeviceInfo` (`id` from `IORegistryEntryGetRegistryEntryID`, `name` incl. "Realtek RTL2832U (R820T2)" / product string, `serial` from the USB serial string property). Release the iterator; the matching dict is consumed by `IOServiceGetMatchingServices`; release non-selected services; return owned services to the caller. (Mirror `IOUSBHostTransport.discover()`'s ref discipline.)
- [ ] **Step 3: Implement `init(service:)`** — `IOCreatePlugInInterfaceForService(service, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID, &plugIn, &score)` → `QueryInterface(kIOUSBDeviceInterfaceID)` → `USBDeviceOpen`. Then `CreateInterfaceIterator` (all-match `IOUSBFindInterfaceRequest`) → first interface → `IOCreatePlugInInterfaceForService(…, kIOUSBInterfaceUserClientTypeID, …)` → `QueryInterface(kIOUSBInterfaceInterfaceID)` → `USBInterfaceOpen`. Store both interfaces + release plug-ins/iterators. Map every failure to `SDRError.usb(String(describing:))`. Stub the three `USBTransport` methods (throw `SDRError.usb("Task 2/3")`).
- [ ] **Step 4: Build + live discovery check.** `swift build` (zero warnings). Add a TEMPORARY gated probe (env `CORESDR_HW_PROBE=1`, `@testable`) that calls `IOUSBLibTransport.discover()` then `init(service:)` on the first result, and prints the device info + "opened OK" (or the error). Run `CORESDR_HW_PROBE=1 swift test --filter <probe>` with the dongle connected → confirms it discovers 1 device and opens it (device + interface). DELETE the probe after. `swift test` (no probe) → 36/36 still green.
- [ ] **Step 5: Commit.** `git commit -m "feat: IOUSBLib transport discovery and device/interface open"`

---

## Task 2: Control transfers (`DeviceRequest`)

**Files:** Modify `Sources/CoreSDR/Transport/IOUSBLibTransport.swift`

**Interfaces:** Implements `controlWrite(_:data:)` and `controlRead(_:length:)` on `IOUSBLibTransport`.

- [ ] **Step 1: Implement** both via `(*device)->DeviceRequest(device, &req)` with an `IOUSBDevRequest` built from `USBControlRequest` (`bmRequestType = requestType`, `bRequest = request`, `wValue = value`, `wIndex = index`, `wLength = data.count`/`length`, `pData` = buffer). `kUSBOut`/`kUSBIn` direction is already encoded in `requestType` (0x40/0xC0). Bridge the synchronous call to `async` (run it and return/throw). Reads return the first `wLenDone` bytes. Failures → `SDRError.usb`.
- [ ] **Step 2: Build + live control round-trip.** `swift build` (zero warnings). Temporary gated probe: open the device, run `RTL2832U(transport:).initBaseband()`, then read back a demod register (or the FIR path as the IOUSBHost transport was validated) and confirm a plausible, non-throwing result — i.e. a real control round-trip over the wire. Print the read bytes. Run with `CORESDR_HW_PROBE=1`, confirm, DELETE the probe. `swift test` → 36/36 green.
- [ ] **Step 3: Commit.** `git commit -m "feat: IOUSBLib control transfers via DeviceRequest"`

---

## Task 3: Bulk-IN streaming (`ReadPipeAsync` ring on a CFRunLoop thread)

**Files:** Modify `Sources/CoreSDR/Transport/IOUSBLibTransport.swift`

**Interfaces:** Implements `bulkStream(endpoint: UInt8, transferSize: Int, inFlight: Int) -> AsyncThrowingStream<[UInt8], Error>`.

- [ ] **Step 1: Implement.** Find the bulk-IN pipe ref for endpoint `0x81`: `GetNumEndpoints`, then `GetPipeProperties(pipeRef, …)` to match direction=In/type=Bulk/number=1 (pipe refs are 1-based; endpoint address 0x81 = IN, endpoint 1). Create the interface async event source: `CreateInterfaceAsyncEventSource(interface, &source)` and add it to a **dedicated thread**'s `CFRunLoop` (spawn a Thread that adds the source and runs `CFRunLoopRun()`). Keep `inFlight` `ReadPipeAsync(interface, pipeRef, buffer, UInt32(transferSize), completionCallback, refcon)` requests outstanding. Each completion (on the run-loop thread) yields the received bytes (`arg` = bytesTransferred via the callback) to the `AsyncThrowingStream` continuation and re-submits another read (the ring). On `continuation.onTermination`: set a stopped flag, `AbortPipe(interface, pipeRef)`, stop the run loop (`CFRunLoopStop`), join/exit the thread, release the source. Protect the ring/stopped state with an `NSLock`; make "check stopped → submit" atomic with "flip stopped → abort" (same TOCTOU discipline as `IOUSBHostTransport`). Map device-removal IOReturn (`kIOReturnNoDevice`/`NotResponding`/`NotAttached`/`kIOReturnAborted` handled as clean stop) → finish with `SDRError.deviceDisconnected` where appropriate.
- [ ] **Step 2: Build + live bulk check.** `swift build` (zero warnings). Temporary gated probe: open + `initBaseband` + `setSampleRate(.rate2_4M)` + tuner init + `resetBuffer`, then start `bulkStream(endpoint: 0x81, transferSize: 16384, inFlight: 4)`, collect ~5 blocks, assert each is 16384 bytes and non-zero, then break (triggers `onTermination` → clean abort). Print counts/sizes. Also start/stop/restart once to exercise teardown. Run `CORESDR_HW_PROBE=1`, confirm, DELETE the probe. `swift test` → 36/36 green.
- [ ] **Step 3: Commit.** `git commit -m "feat: IOUSBLib bulk-IN streaming with in-flight ring"`

---

## Task 4: Wire it in, delete IOUSBHost, validate end-to-end

**Files:**
- Modify: the discovery/open wiring that constructs the transport (search for `IOUSBHostTransport` usages — `SDRDevice.discover()`/`default`/`open(_:)` and any `Discovery.swift`/factory) → use `IOUSBLibTransport`.
- Delete: `Sources/CoreSDR/Transport/IOUSBHostTransport.swift`.

**Interfaces:** No public API change. `SDRDevice.discover()`/`default`/`open(_:)` now build an `IOUSBLibTransport`.

- [ ] **Step 1: Replace** every `IOUSBHostTransport` reference with `IOUSBLibTransport` (discovery + the transport constructed for a chosen `SDRDeviceInfo`). Delete `IOUSBHostTransport.swift`. `grep -r IOUSBHost Sources` must return nothing.
- [ ] **Step 2: Build + full live validation.** `swift build` (zero warnings). `swift test` → 36/36 green (mock suite unaffected). Then the hardware path: `swift run coresdr-demo --tune 104.9` → confirms discover → open → tune → stream over `IOUSBLibTransport` (real IQ blocks, non-trivial power — BBC Radio Leicester). Also run the hardware-gated integration test: `CORESDR_HW_TEST=1 CORESDR_HW_FREQ_MHZ=104.9 swift test --filter HardwareTests` → passes over the new transport. Default `swift test` still skips it.
- [ ] **Step 3: Commit.** `git commit -m "feat: use IOUSBLib transport; remove IOUSBHost transport"`

---

## Task 5: README rationale + 1.1.0 release

**Files:** Modify `README.md`; bump version references.

- [ ] **Step 1: Add a "Why IOUSBLib (and the App Sandbox)" section** to `README.md`: `com.apple.security.device.usb` covers the legacy IOKit USB user clients (`IOUSBDeviceUserClientV2`/`InterfaceUserClientV3`) that `IOUSBLib` opens, but NOT `IOUSBHost.framework`'s (`AppleUSBHostFrameworkDeviceClient`), which would need a MAS-forbidden `temporary-exception.iokit-user-client-class`. So CoreSDR uses `IOUSBLib` → a sandboxed app (incl. Mac App Store) accesses the device with just `com.apple.security.device.usb`, no temporary-exception. Note IOUSBLib is deprecated-but-supported (libusb uses it) and that the `USBTransport` seam keeps IOUSBHost re-addable if ever needed. Update any transport-specific wording elsewhere (the sandbox note / feature list) to match.
- [ ] **Step 2: Verify** `swift build && swift test` green (docs change), commit. `git commit -m "docs: explain IOUSBLib transport and sandbox/MAS rationale"`
- [ ] **Step 3: Release 1.1.0** (controller does this at finish): merge to main per the finishing skill, then tag `1.1.0` + GitHub release noting the sandbox/MAS-eligible transport change (consumers can drop the temporary-exception).

---

## Self-Review

**Spec coverage:** IOUSBLibTransport open/control/bulk → Tasks 1–3. Legacy `IOUSBDevice` discovery matching → Task 1. Wire-in + delete IOUSBHost → Task 4. Unchanged driver/test layers → verified green in every task (36 tests). README rationale → Task 5. Release 1.1.0 → Task 5. No public API change → nothing above the seam is touched.

**Placeholder scan:** The transport's IOKit sequences are specified with the exact API calls and reference the proven spike `usbspike.c` + the existing `IOUSBHostTransport.swift` for structure/ref-discipline; live-validation steps are concrete (control round-trip, bulk block counts, end-to-end tune). No vague "add error handling" gaps.

**Type consistency:** `IOUSBLibTransport` conforms to the unchanged `USBTransport` (`controlWrite`/`controlRead`/`bulkStream` — exact signatures) and matches `IOUSBHostTransport`'s `discover()`/`init(service:)` shape, so the discovery/open wiring swaps 1:1. `USBControlRequest` fields (`requestType`/`request`/`value`/`index`) map onto `IOUSBDevRequest` as stated.
