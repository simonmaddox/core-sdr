import Foundation
import IOKit
import IOKit.usb
import IOUSBHost

/// Real-hardware `USBTransport` backed by Apple's IOUSBHost framework.
///
/// Task 20 implements discovery and the opening `init` only: it enumerates RTL-SDR
/// dongles, builds `SDRDeviceInfo`, opens the `IOUSBHostDevice`, and claims interface 0
/// as an `IOUSBHostInterface`. The three `USBTransport` transfer methods
/// (`controlWrite` / `controlRead` / `bulkStream`) are implemented in Task 21 and are
/// throwing stubs here.
///
/// Concurrency: `@unchecked Sendable` is used because the compiler cannot reason about
/// the imported IOUSBHost Objective-C objects. It is sound here: every stored property is
/// an immutable `let`, and `IOUSBHostDevice` / `IOUSBHostInterface` are internally
/// synchronised on their own serial dispatch queues. Control transfers add no mutable
/// state; the mutable in-flight bulk-transfer bookkeeping lives in a per-stream
/// `BulkReader`, which guards it with its own `NSLock` (see `bulkStream`).
final class IOUSBHostTransport: USBTransport, @unchecked Sendable {

    /// The opened USB device. Retains its own reference to the underlying `io_service_t`.
    private let device: IOUSBHostDevice
    /// Interface 0, claimed for control + bulk transfers. Retains its own `io_service_t`.
    private let interface: IOUSBHostInterface

    /// Timeout for a single control transfer. `0` would mean "never time out"; a finite
    /// value guards against a wedged transfer hanging an `await` forever. Control transfers
    /// here are a few bytes of register I/O, so one second is very generous.
    private static let controlTimeout: TimeInterval = 1.0

    // MARK: - Discovery

    /// Enumerates attached RTL-SDR dongles.
    ///
    /// Returns one entry per matching device. Each `service` is a live `io_service_t`
    /// **owned by the caller**: release it with `IOObjectRelease`, or pass it to
    /// `init(service:)` (which retains its own reference, so the caller must still release
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
    /// `IOUSBHostDevice`/`IOUSBHostInterface` keep their own references to the services
    /// they wrap.
    init(service: io_service_t) throws {
        let device = try Self.openDevice(service)
        self.device = device

        // The device is usually already configured to value 1 by the system, so try to
        // locate interface 0 as a published child first — this avoids tearing down a
        // working configuration.
        if let iface = Self.findInterfaceZero(deviceService: service) {
            self.interface = iface
            return
        }

        // Not yet published: select configuration 1 so the interfaces are registered for
        // matching, then poll briefly (the header warns interfaces are "not guaranteed to
        // be immediately available" after configuring).
        try Self.configureDeviceValueOne(device)
        guard let iface = Self.findInterfaceZero(deviceService: service, retries: 20) else {
            throw SDRError.usb("IOUSBHostTransport: interface 0 not found after configuring device")
        }
        self.interface = iface
    }

    private static func openDevice(_ service: io_service_t) throws -> IOUSBHostDevice {
        do {
            return try IOUSBHostDevice(
                __ioService: service, options: [], queue: nil, interestHandler: nil
            )
        } catch {
            throw SDRError.usb("IOUSBHostTransport: failed to open IOUSBHostDevice: \(error)")
        }
    }

    private static func configureDeviceValueOne(_ device: IOUSBHostDevice) throws {
        do {
            try device.__configure(withValue: 1, matchInterfaces: true)
        } catch {
            throw SDRError.usb("IOUSBHostTransport: failed to configure device (value 1): \(error)")
        }
    }

    /// Locates interface 0 among the device's immediate children and opens it as an
    /// `IOUSBHostInterface`. Returns `nil` if no matching interface is published yet.
    ///
    /// Ownership: child services obtained from `IOIteratorNext` are released here; the
    /// returned `IOUSBHostInterface` retains its own reference to the interface service.
    private static func findInterfaceZero(
        deviceService: io_service_t, retries: Int = 0
    ) -> IOUSBHostInterface? {
        for attempt in 0...max(0, retries) {
            if attempt > 0 {
                // Brief back-off while the newly-configured interfaces register (~10ms).
                Thread.sleep(forTimeInterval: 0.010)
            }
            if let interfaceService = firstInterfaceZeroService(deviceService: deviceService) {
                defer { IOObjectRelease(interfaceService) }
                if let interface = try? IOUSBHostInterface(
                    __ioService: interfaceService, options: [], queue: nil, interestHandler: nil
                ) {
                    return interface
                }
            }
        }
        return nil
    }

    /// Returns a retained `io_service_t` for the device's interface number 0, or
    /// `IO_OBJECT_NULL`. Caller must `IOObjectRelease` a non-null result.
    private static func firstInterfaceZeroService(deviceService: io_service_t) -> io_service_t? {
        var childIterator: io_iterator_t = IO_OBJECT_NULL
        guard IORegistryEntryGetChildIterator(deviceService, kIOServicePlane, &childIterator) == KERN_SUCCESS,
              childIterator != IO_OBJECT_NULL else {
            return nil
        }
        defer { IOObjectRelease(childIterator) }

        var match: io_service_t = IO_OBJECT_NULL
        var child = IOIteratorNext(childIterator)
        while child != IO_OBJECT_NULL {
            if IOObjectConformsTo(child, "IOUSBHostInterface") != 0 {
                let number = interfaceNumber(child)
                // Accept interface number 0, or an interface with no reported number
                // (RTL2832U exposes a single interface).
                if number == nil || number == 0 {
                    match = child   // keep this reference for the caller
                    break
                }
            }
            IOObjectRelease(child)
            child = IOIteratorNext(childIterator)
        }
        return match == IO_OBJECT_NULL ? nil : match
    }

    /// Reads `bInterfaceNumber` from an interface service, or `nil` if unavailable.
    private static func interfaceNumber(_ service: io_service_t) -> Int? {
        guard let property = IORegistryEntryCreateCFProperty(
            service, "bInterfaceNumber" as CFString, kCFAllocatorDefault, 0
        ) else {
            return nil
        }
        return (property.takeRetainedValue() as? NSNumber)?.intValue
    }

    // MARK: - USBTransport — control transfers

    /// Control OUT: sends `data` on the default control endpoint (EP0).
    func controlWrite(_ request: USBControlRequest, data: [UInt8]) async throws {
        _ = try await sendControl(request, outgoing: data, length: data.count)
    }

    /// Control IN: reads up to `length` bytes from the default control endpoint (EP0).
    func controlRead(_ request: USBControlRequest, length: Int) async throws -> [UInt8] {
        try await sendControl(request, outgoing: nil, length: length)
    }

    /// Issues one control transfer on EP0 and returns the bytes present in the data phase.
    ///
    /// For an OUT transfer pass the bytes in `outgoing` (they seed the data buffer); the
    /// returned array is empty. For an IN transfer pass `outgoing == nil` and the number of
    /// bytes to read in `length`; the returned array holds exactly the bytes the device
    /// actually transferred (`bytesTransferred`), which may be shorter than `length`.
    ///
    /// Uses the asynchronous `enqueueDeviceRequest` form bridged to `async` so no thread in
    /// the cooperative pool is blocked while the transfer is in flight. The completion runs
    /// on the device's serial dispatch queue.
    private func sendControl(
        _ request: USBControlRequest, outgoing: [UInt8]?, length: Int
    ) async throws -> [UInt8] {
        var deviceRequest = IOUSBDeviceRequest()
        deviceRequest.bmRequestType = request.requestType
        deviceRequest.bRequest = request.request
        deviceRequest.wValue = request.value
        deviceRequest.wIndex = request.index
        deviceRequest.wLength = UInt16(clamping: length)

        // Backing buffer for the data phase (nil for a zero-length transfer).
        let buffer: NSMutableData?
        if length == 0 {
            buffer = nil
        } else if let outgoing {
            buffer = NSMutableData(bytes: outgoing, length: outgoing.count)
        } else {
            buffer = NSMutableData(length: length)
        }

        let transferred = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Int, Error>) in
            do {
                try device.__enqueue(
                    deviceRequest, data: buffer, completionTimeout: Self.controlTimeout
                ) { status, bytesTransferred in
                    switch status {
                    case kIOReturnSuccess:
                        continuation.resume(returning: bytesTransferred)
                    case kIOReturnNoDevice, kIOReturnNotResponding, kIOReturnNotAttached:
                        // Match the bulk path: a control transfer on an unplugged device
                        // reports disconnect rather than a generic USB error.
                        continuation.resume(throwing: SDRError.deviceDisconnected)
                    default:
                        continuation.resume(
                            throwing: SDRError.usb(
                                "control transfer failed: \(Self.ioReturnDescription(status))"
                            )
                        )
                    }
                }
            } catch {
                // `__enqueue` rejected the request synchronously; the completion handler
                // will never fire, so resume here.
                continuation.resume(throwing: SDRError.usb(String(describing: error)))
            }
        }

        guard let buffer, transferred > 0 else { return [] }
        let count = min(transferred, buffer.length)
        let base = buffer.bytes.assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: base, count: count))
    }

    // MARK: - USBTransport — bulk streaming

    /// Continuous bulk-IN stream. Keeps `inFlight` reads of `transferSize` bytes outstanding
    /// on the pipe for `endpoint`; each completion yields its bytes and re-enqueues a fresh
    /// read, so the ring depth stays constant. Terminating/cancelling the stream aborts the
    /// pipe (see `BulkReader`).
    func bulkStream(
        endpoint: UInt8, transferSize: Int, inFlight: Int
    ) -> AsyncThrowingStream<[UInt8], Error> {
        AsyncThrowingStream { continuation in
            let pipe: IOUSBHostPipe
            do {
                pipe = try interface.copyPipe(withAddress: Int(endpoint))
            } catch {
                continuation.finish(throwing: SDRError.usb(
                    "bulkStream: copyPipe(0x\(String(endpoint, radix: 16))) failed: \(error)"
                ))
                return
            }

            let reader = BulkReader(
                pipe: pipe, transferSize: transferSize, continuation: continuation
            )
            continuation.onTermination = { _ in reader.stop() }
            reader.start(inFlight: max(1, inFlight))
        }
    }

    /// Human-readable IOReturn code (hex) for error messages.
    private static func ioReturnDescription(_ status: IOReturn) -> String {
        "IOReturn 0x" + String(format: "%08x", UInt32(bitPattern: status))
    }
}

/// Drives one bulk-IN stream: a fixed-depth ring of asynchronous pipe reads that yields
/// each completed transfer to an `AsyncThrowingStream`.
///
/// Concurrency: `@unchecked Sendable`. Completion handlers fire on the pipe's serial
/// dispatch queue (a thread distinct from the consumer). The only mutable state is
/// `stopped`, guarded by `lock`; `pipe` and `continuation` are immutable `let`s and are
/// themselves thread-safe. Completion closures retain `self` strongly so the reader — and
/// therefore the `pipe` and its in-flight buffers — stay alive until every outstanding
/// read has completed, even after the stream finishes.
/// Carries a non-`Sendable` value across a `@Sendable` closure boundary where the caller
/// guarantees single-threaded access. Used to hand each bulk transfer's `NSMutableData`
/// buffer to its completion handler.
private struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

private final class BulkReader: @unchecked Sendable {
    private let pipe: IOUSBHostPipe
    private let transferSize: Int
    private let continuation: AsyncThrowingStream<[UInt8], Error>.Continuation
    private let lock = NSLock()
    /// Once true, no new reads are enqueued and completions are ignored.
    private var stopped = false

    init(
        pipe: IOUSBHostPipe,
        transferSize: Int,
        continuation: AsyncThrowingStream<[UInt8], Error>.Continuation
    ) {
        self.pipe = pipe
        self.transferSize = transferSize
        self.continuation = continuation
    }

    /// Primes the ring with `inFlight` outstanding reads.
    func start(inFlight: Int) {
        for _ in 0..<inFlight { enqueueOne() }
    }

    /// Enqueues a single read unless the stream has stopped.
    ///
    /// The `stopped` check and the `enqueueIORequest` submission are performed **together
    /// under `lock`**, the same lock `stop()`/`finish()` hold while flipping `stopped` and
    /// aborting the pipe. This makes "check → submit" atomic with respect to "flip → abort",
    /// closing the TOCTOU window in which a fresh read could be submitted *after* the pipe
    /// was aborted (which would never complete and leak the reader/pipe). Either this
    /// submission happens fully before the flip (and is cancelled by the subsequent abort),
    /// or it observes `stopped == true` and skips.
    ///
    /// Holding `lock` across `enqueueIORequest` is deadlock-free: the call only *submits*
    /// asynchronously; its completion (`handle()`) fires later on the pipe's serial queue,
    /// never re-entrantly inside the call. (`__abort`/`yield`/`continuation.finish` are the
    /// blocking/re-entrant operations, and those are all kept OUTSIDE the lock.)
    private func enqueueOne() {
        guard let buffer = NSMutableData(length: transferSize) else {
            finish(with: SDRError.usb(
                "bulkStream: failed to allocate \(transferSize)-byte transfer buffer"
            ))
            return
        }
        // The completion handler is `@Sendable` but `NSMutableData` is not `Sendable`.
        // Passing the buffer through `UncheckedSendable` is sound: this buffer is owned by
        // exactly one in-flight transfer and is only ever read inside that transfer's single
        // completion (on the pipe's serial queue), so there is no concurrent access.
        let box = UncheckedSendable(buffer)

        var enqueueError: Error?
        lock.lock()
        if !stopped {
            do {
                try pipe.enqueueIORequest(with: buffer, completionTimeout: 0) { [self] status, transferred in
                    handle(status: status, transferred: transferred, buffer: box.value)
                }
            } catch {
                enqueueError = error
            }
        }
        lock.unlock()

        // Report a synchronous submission failure after releasing the lock (`finish` re-takes
        // it and calls back into the continuation).
        if let enqueueError {
            finish(with: SDRError.usb("bulkStream: enqueue failed: \(enqueueError)"))
        }
    }

    /// Handles one completed read: yield its bytes and re-enqueue, or map the failure.
    private func handle(status: IOReturn, transferred: Int, buffer: NSMutableData) {
        lock.lock()
        let alreadyStopped = stopped
        lock.unlock()
        guard !alreadyStopped else { return }

        switch status {
        case kIOReturnSuccess:
            if transferred > 0 {
                let count = min(transferred, buffer.length)
                let base = buffer.bytes.assumingMemoryBound(to: UInt8.self)
                continuation.yield(Array(UnsafeBufferPointer(start: base, count: count)))
            }
            enqueueOne()
        case kIOReturnAborted:
            // Expected once `stop()`/`finish()` has aborted the pipe; drop silently.
            return
        case kIOReturnNoDevice, kIOReturnNotResponding, kIOReturnNotAttached:
            finish(with: SDRError.deviceDisconnected)
        default:
            finish(with: SDRError.usb(
                "bulkStream: read failed: IOReturn 0x"
                    + String(format: "%08x", UInt32(bitPattern: status))
            ))
        }
    }

    /// Finishes the stream with an error and aborts the pipe. Idempotent.
    private func finish(with error: Error) {
        lock.lock()
        if stopped { lock.unlock(); return }
        stopped = true
        // Flip `stopped` and abort atomically under `lock` so no `enqueueOne()` can submit a
        // read between the two. Asynchronous abort is required here: `finish` may be called
        // from within a completion handler on the pipe's serial queue, and it only *requests*
        // cancellation (returns without waiting), so it neither blocks nor re-enters `handle`.
        // Remaining reads complete with kIOReturnAborted and are dropped.
        try? pipe.__abort(with: .asynchronous)
        lock.unlock()
        // `continuation.finish` is kept outside the lock (it may synchronously run the
        // consumer's `onTermination`, i.e. `stop()`, which takes the same lock).
        continuation.finish(throwing: error)
    }

    /// Stops the ring and aborts the pipe. Invoked from `onTermination` (consumer cancelled
    /// or broke out of the loop). Idempotent.
    func stop() {
        lock.lock()
        if stopped { lock.unlock(); return }
        stopped = true
        // Same atomic flip+abort under `lock` as `finish()`, mutually exclusive with the
        // check+submit in `enqueueOne()`.
        try? pipe.__abort(with: .asynchronous)
        lock.unlock()
    }
}
