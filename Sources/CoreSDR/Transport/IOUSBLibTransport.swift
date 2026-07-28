import Foundation
import IOKit
import IOKit.usb
import IOKit.usb.IOUSBLib

/// Real-hardware `USBTransport` backed by Apple's **legacy IOUSBLib** COM API.
///
/// Unlike `IOUSBHost` (which requires a temporary-exception entitlement and is therefore
/// not Mac App Store eligible), the legacy `IOUSBDeviceInterface` / `IOUSBInterfaceInterface`
/// plug-ins are reachable from a sandboxed app holding only `com.apple.security.device.usb`.
///
/// Task 1 implements discovery and the opening `init` only: it enumerates RTL-SDR dongles,
/// builds `SDRDeviceInfo`, opens the `IOUSBDeviceInterface`, and claims interface 0 as an
/// `IOUSBInterfaceInterface`. The three `USBTransport` transfer methods
/// (`controlWrite` / `controlRead` / `bulkStream`) are filled in by Tasks 2-3 and are
/// throwing stubs here.
///
/// ## IOUSBLib COM interop
/// All `(*iface)->Method(iface, …)` C-style COM calls are quarantined to this file. In Swift
/// a COM interface handle is a doubly-indirected pointer to a v-table of `@convention(c)`
/// function pointers, so a call becomes `handle.pointee!.pointee.Method(rawSelf, …)` where
/// `rawSelf` is the handle re-cast to the untyped `self` the C prototype expects.
///
/// The UUID constants (`kIOUSBDeviceUserClientTypeID`, `kIOCFPlugInInterfaceID`,
/// `kIOUSBDeviceInterfaceID`, …) are function-like `CFUUIDGetConstantUUIDWithBytes(…)` macros
/// that do not import into Swift, so they are reconstructed from their documented byte
/// values (see `IOUSBLib.h` / `IOCFPlugIn.h`). We request the `…942` interface UUIDs because
/// Swift's `IOUSBDeviceInterface` / `IOUSBInterfaceInterface` typedefs resolve to the newest
/// `…942` struct layout — matching the requested UUID to the Swift v-table type keeps every
/// member access in-bounds.
///
/// ## Concurrency
/// `@unchecked Sendable`: the compiler cannot reason about the raw IOKit COM pointers. It is
/// sound here for the same reason as `IOUSBHostTransport`: every stored handle is an
/// immutable `let` assigned once in `init` and never mutated afterwards. The underlying
/// IOUSBLib device/interface objects are internally serialised by IOUSBFamily. The transfer
/// methods added in Tasks 2-3 introduce their own synchronisation for any in-flight state.
final class IOUSBLibTransport: USBTransport, @unchecked Sendable {

    /// Doubly-indirected handle to the opened `IOUSBDeviceInterface` COM object.
    private let device: UnsafeMutablePointer<UnsafeMutablePointer<IOUSBDeviceInterface>?>
    /// Doubly-indirected handle to interface 0's `IOUSBInterfaceInterface` COM object.
    private let interface: UnsafeMutablePointer<UnsafeMutablePointer<IOUSBInterfaceInterface>?>

    // MARK: - COM UUIDs (reconstructed from IOUSBLib.h / IOCFPlugIn.h byte values)

    // Computed rather than stored so no non-`Sendable` `CFUUID` becomes global mutable
    // state under Swift 6. `CFUUIDGetConstantUUIDWithBytes` returns an interned singleton,
    // so recomputation is free.

    /// `kIOCFPlugInInterfaceID` — C244E858-109C-11D4-91D4-0050E4C6426F.
    private static var plugInInterfaceID: CFUUID {
        CFUUIDGetConstantUUIDWithBytes(
            nil,
            0xC2, 0x44, 0xE8, 0x58, 0x10, 0x9C, 0x11, 0xD4,
            0x91, 0xD4, 0x00, 0x50, 0xE4, 0xC6, 0x42, 0x6F
        )
    }

    /// `kIOUSBDeviceUserClientTypeID` — 9dc7b780-9ec0-11d4-a54f-000a27052861.
    private static var deviceUserClientTypeID: CFUUID {
        CFUUIDGetConstantUUIDWithBytes(
            nil,
            0x9D, 0xC7, 0xB7, 0x80, 0x9E, 0xC0, 0x11, 0xD4,
            0xA5, 0x4F, 0x00, 0x0A, 0x27, 0x05, 0x28, 0x61
        )
    }

    /// `kIOUSBInterfaceUserClientTypeID` — 2d9786c6-9ef3-11d4-ad51-000a27052861.
    private static var interfaceUserClientTypeID: CFUUID {
        CFUUIDGetConstantUUIDWithBytes(
            nil,
            0x2D, 0x97, 0x86, 0xC6, 0x9E, 0xF3, 0x11, 0xD4,
            0xAD, 0x51, 0x00, 0x0A, 0x27, 0x05, 0x28, 0x61
        )
    }

    /// `kIOUSBDeviceInterfaceID942` — 56AD089D-878D-4BEA-A1F5-2C8DC43E8A98.
    /// Matches the `IOUSBDeviceInterface` typedef's `…942` struct layout.
    private static var deviceInterfaceID: CFUUID {
        CFUUIDGetConstantUUIDWithBytes(
            nil,
            0x56, 0xAD, 0x08, 0x9D, 0x87, 0x8D, 0x4B, 0xEA,
            0xA1, 0xF5, 0x2C, 0x8D, 0xC4, 0x3E, 0x8A, 0x98
        )
    }

    /// `kIOUSBInterfaceInterfaceID942` — 8752663B-C07B-4BAE-9584-22032FAB9C5A.
    /// Matches the `IOUSBInterfaceInterface` typedef's `…942` struct layout.
    private static var interfaceInterfaceID: CFUUID {
        CFUUIDGetConstantUUIDWithBytes(
            nil,
            0x87, 0x52, 0x66, 0x3B, 0xC0, 0x7B, 0x4B, 0xAE,
            0x95, 0x84, 0x22, 0x03, 0x2F, 0xAB, 0x9C, 0x5A
        )
    }

    // MARK: - Discovery

    /// Enumerates attached RTL-SDR dongles.
    ///
    /// Returns one entry per matching device. Each `service` is a live `io_service_t`
    /// **owned by the caller**: release it with `IOObjectRelease`, or pass it to
    /// `init(service:)` (which retains its own references, so the caller must still release
    /// the handle it was given afterwards).
    static func discover() throws -> [(info: SDRDeviceInfo, service: io_service_t)] {
        let services = USBDeviceMatching.matchingRTLServices()
        var results: [(info: SDRDeviceInfo, service: io_service_t)] = []
        results.reserveCapacity(services.count)
        for service in services {
            results.append((info: deviceInfo(for: service), service: service))
        }
        return results
    }

    /// Builds `SDRDeviceInfo` from IORegistry properties without opening the device.
    private static func deviceInfo(for service: io_service_t) -> SDRDeviceInfo {
        // Stable per-physical-port identifier from the IOKit registry entry ID.
        var entryID: UInt64 = 0
        let id: String
        if IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS {
            id = String(format: "usb-rtlsdr-%016llx", entryID)
        } else {
            id = "usb-rtlsdr-unknown"
        }

        let serial = registryString(service, key: "USB Serial Number")
        let product = registryString(service, key: "USB Product Name")
        let vid = USBDeviceMatching.rtlVendorID
        let pid = USBDeviceMatching.rtlProductID
        let name = product.map { "\($0) (RTL2832U)" }
            ?? String(format: "RTL-SDR (RTL2832U, VID 0x%04x PID 0x%04x)", vid, pid)

        return SDRDeviceInfo(id: id, name: name, serial: serial)
    }

    /// Reads a string-valued IORegistry property, or `nil` if absent / not a string.
    private static func registryString(_ service: io_service_t, key: String) -> String? {
        guard let property = IORegistryEntryCreateCFProperty(
            service, key as CFString, kCFAllocatorDefault, 0
        ) else {
            return nil
        }
        return property.takeRetainedValue() as? String
    }

    // MARK: - Open

    /// Opens the device behind `service` and claims interface 0.
    ///
    /// The caller retains ownership of `service` (this initializer does not release it);
    /// the created COM objects keep their own references to the underlying services.
    ///
    /// Sequence (mirrors the proven C spike):
    /// 1. `IOCreatePlugInInterfaceForService(… kIOUSBDeviceUserClientTypeID …)`
    /// 2. `plugIn->QueryInterface(kIOUSBDeviceInterfaceID)` → `IOUSBDeviceInterface`
    /// 3. `dev->USBDeviceOpen`
    /// 4. `dev->CreateInterfaceIterator(all-match)` → first interface `io_service_t`
    /// 5. `IOCreatePlugInInterfaceForService(… kIOUSBInterfaceUserClientTypeID …)`
    /// 6. `plugIn->QueryInterface(kIOUSBInterfaceInterfaceID)` → `IOUSBInterfaceInterface`
    /// 7. `intf->USBInterfaceOpen`
    init(service: io_service_t) throws {
        // --- Device COM interface ---
        let device: UnsafeMutablePointer<UnsafeMutablePointer<IOUSBDeviceInterface>?> =
            try Self.createInterface(
                for: service,
                userClientType: Self.deviceUserClientTypeID,
                interfaceID: Self.deviceInterfaceID,
                as: IOUSBDeviceInterface.self,
                what: "IOUSBDeviceInterface"
            )

        let openResult = device.pointee!.pointee.USBDeviceOpen(device)
        guard openResult == kIOReturnSuccess else {
            _ = device.pointee!.pointee.Release(device)
            throw SDRError.usb("USBDeviceOpen failed: \(Self.ioReturnDescription(openResult))")
        }

        // --- First interface's io_service_t ---
        let interfaceService: io_service_t
        do {
            interfaceService = try Self.firstInterfaceService(of: device)
        } catch {
            _ = device.pointee!.pointee.USBDeviceClose(device)
            _ = device.pointee!.pointee.Release(device)
            throw error
        }
        defer { IOObjectRelease(interfaceService) }

        // --- Interface COM interface ---
        let interface: UnsafeMutablePointer<UnsafeMutablePointer<IOUSBInterfaceInterface>?>
        do {
            interface = try Self.createInterface(
                for: interfaceService,
                userClientType: Self.interfaceUserClientTypeID,
                interfaceID: Self.interfaceInterfaceID,
                as: IOUSBInterfaceInterface.self,
                what: "IOUSBInterfaceInterface"
            )
        } catch {
            _ = device.pointee!.pointee.USBDeviceClose(device)
            _ = device.pointee!.pointee.Release(device)
            throw error
        }

        let interfaceOpen = interface.pointee!.pointee.USBInterfaceOpen(interface)
        guard interfaceOpen == kIOReturnSuccess else {
            _ = interface.pointee!.pointee.Release(interface)
            _ = device.pointee!.pointee.USBDeviceClose(device)
            _ = device.pointee!.pointee.Release(device)
            throw SDRError.usb("USBInterfaceOpen failed: \(Self.ioReturnDescription(interfaceOpen))")
        }

        self.device = device
        self.interface = interface
    }

    deinit {
        _ = interface.pointee!.pointee.USBInterfaceClose(interface)
        _ = interface.pointee!.pointee.Release(interface)
        _ = device.pointee!.pointee.USBDeviceClose(device)
        _ = device.pointee!.pointee.Release(device)
    }

    // MARK: - COM plumbing

    /// Creates an IOUSBLib COM interface for `service`: builds the CFPlugIn, queries it for
    /// `interfaceID`, and returns the doubly-indirected COM handle. Releases the intermediate
    /// plug-in before returning. The returned handle carries one retain (from
    /// `QueryInterface`); the caller must `Release` it when finished.
    private static func createInterface<T>(
        for service: io_service_t,
        userClientType: CFUUID,
        interfaceID: CFUUID,
        as type: T.Type,
        what: String
    ) throws -> UnsafeMutablePointer<UnsafeMutablePointer<T>?> {
        var plugIn: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
        var score: Int32 = 0
        let created = IOCreatePlugInInterfaceForService(
            service, userClientType, plugInInterfaceID, &plugIn, &score
        )
        guard created == kIOReturnSuccess, let plugIn else {
            throw SDRError.usb(
                "IOCreatePlugInInterfaceForService(\(what)) failed: \(ioReturnDescription(created))"
            )
        }
        defer { _ = plugIn.pointee!.pointee.Release(plugIn) }

        var raw: UnsafeMutableRawPointer?
        let queried = plugIn.pointee!.pointee.QueryInterface(
            plugIn,
            CFUUIDGetUUIDBytes(interfaceID),
            &raw
        )
        guard queried == 0, let raw else {
            throw SDRError.usb(
                "QueryInterface(\(what)) failed: hr=0x"
                    + String(format: "%08x", UInt32(bitPattern: queried))
            )
        }
        // `raw`'s pointer value *is* the `T**` COM handle; reinterpret its bit pattern.
        return raw.assumingMemoryBound(to: UnsafeMutablePointer<T>?.self)
    }

    /// Returns a retained `io_service_t` for the device's first USB interface (all-match
    /// find request). Caller must `IOObjectRelease` the result.
    private static func firstInterfaceService(
        of device: UnsafeMutablePointer<UnsafeMutablePointer<IOUSBDeviceInterface>?>
    ) throws -> io_service_t {
        var request = IOUSBFindInterfaceRequest(
            bInterfaceClass: UInt16(kIOUSBFindInterfaceDontCare),
            bInterfaceSubClass: UInt16(kIOUSBFindInterfaceDontCare),
            bInterfaceProtocol: UInt16(kIOUSBFindInterfaceDontCare),
            bAlternateSetting: UInt16(kIOUSBFindInterfaceDontCare)
        )
        var iterator: io_iterator_t = IO_OBJECT_NULL
        let result = device.pointee!.pointee.CreateInterfaceIterator(device, &request, &iterator)
        guard result == kIOReturnSuccess, iterator != IO_OBJECT_NULL else {
            throw SDRError.usb("CreateInterfaceIterator failed: \(ioReturnDescription(result))")
        }
        defer { IOObjectRelease(iterator) }

        let interfaceService = IOIteratorNext(iterator)
        guard interfaceService != IO_OBJECT_NULL else {
            throw SDRError.usb("CreateInterfaceIterator returned no interfaces")
        }
        return interfaceService
    }

    /// Human-readable IOReturn code (hex) for error messages.
    private static func ioReturnDescription(_ status: IOReturn) -> String {
        "IOReturn 0x" + String(format: "%08x", UInt32(bitPattern: status))
    }

    // MARK: - USBTransport — control transfers (Task 2)

    /// Control OUT on EP0: sends `data` to the device.
    ///
    /// `DeviceRequest` is a synchronous (blocking) control transfer, so it is issued
    /// directly inside this `async` method — there is no async IOUSBLib form worth a
    /// continuation for a few bytes of register I/O. The direction (`kUSBOut`, 0x40) is
    /// already encoded in `request.requestType`; it is passed through verbatim as
    /// `bmRequestType`.
    func controlWrite(_ request: USBControlRequest, data: [UInt8]) async throws {
        // A mutable copy keeps the data-phase buffer alive across the DeviceRequest call
        // (`pData` points into it). `withUnsafeMutableBufferPointer` guarantees the storage
        // does not move for the duration of the closure.
        var buffer = data
        try buffer.withUnsafeMutableBufferPointer { ptr in
            var req = IOUSBDevRequest()
            req.bmRequestType = request.requestType
            req.bRequest = request.request
            req.wValue = request.value
            req.wIndex = request.index
            req.wLength = UInt16(clamping: data.count)
            req.pData = ptr.baseAddress.map(UnsafeMutableRawPointer.init)
            req.wLenDone = 0

            let result = device.pointee!.pointee.DeviceRequest(device, &req)
            guard result == kIOReturnSuccess else {
                throw SDRError.usb(
                    "control write (DeviceRequest) failed: \(Self.ioReturnDescription(result))"
                )
            }
        }
    }

    /// Control IN on EP0: reads up to `length` bytes and returns exactly the bytes the
    /// device transferred (`wLenDone`), which may be shorter than `length`.
    ///
    /// The direction (`kUSBIn`, 0xC0) is already encoded in `request.requestType` and
    /// passed through as `bmRequestType`.
    func controlRead(_ request: USBControlRequest, length: Int) async throws -> [UInt8] {
        guard length > 0 else { return [] }

        // Data-phase buffer; `pData` points into it and it must outlive the blocking call.
        var buffer = [UInt8](repeating: 0, count: length)
        let transferred: Int = try buffer.withUnsafeMutableBufferPointer { ptr in
            var req = IOUSBDevRequest()
            req.bmRequestType = request.requestType
            req.bRequest = request.request
            req.wValue = request.value
            req.wIndex = request.index
            req.wLength = UInt16(clamping: length)
            req.pData = UnsafeMutableRawPointer(ptr.baseAddress)
            req.wLenDone = 0

            let result = device.pointee!.pointee.DeviceRequest(device, &req)
            guard result == kIOReturnSuccess else {
                throw SDRError.usb(
                    "control read (DeviceRequest) failed: \(Self.ioReturnDescription(result))"
                )
            }
            // `wLenDone` is the actual data-phase length; clamp to the buffer for safety.
            return min(Int(req.wLenDone), ptr.count)
        }
        return Array(buffer.prefix(transferred))
    }

    // MARK: - USBTransport — bulk streaming (Task 3)

    // TODO(Task 3): drive a fixed-depth ring of async bulk-IN reads on the interface pipe
    // via `interface->ReadPipeAsync` and an async event source.
    func bulkStream(
        endpoint: UInt8, transferSize: Int, inFlight: Int
    ) -> AsyncThrowingStream<[UInt8], Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: SDRError.usb("bulkStream not implemented — Task 2/3"))
        }
    }
}
