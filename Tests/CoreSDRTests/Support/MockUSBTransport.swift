import Foundation
@testable import CoreSDR

/// Test-only `USBTransport` conformer that records every control transfer and
/// serves canned responses, so the RTL driver can be TDD'd without hardware.
///
/// Thread-safety: all mutable state is guarded by `lock` so the mock can be
/// driven from `async` contexts (potentially hopping executors) without data
/// races. It is `@unchecked Sendable` because the compiler cannot verify the
/// manual locking discipline used below.
final class MockUSBTransport: USBTransport, @unchecked Sendable {
    private struct StubKey: Hashable {
        var value: UInt16
        var index: UInt16
    }

    /// The demod dummy read (`value: 0x0001, index: 0x000a`) that RTL2832U
    /// init performs before it cares about the result. Un-stubbed reads of
    /// this specific register return `[0x00]` rather than zero-filled bytes
    /// of the requested length, so driver init code doesn't need to stub it
    /// explicitly in every test.
    private static let demodDummyReadKey = StubKey(value: 0x0001, index: 0x000a)

    private let lock = NSLock()
    private var _controlWrites: [(request: USBControlRequest, data: [UInt8])] = []
    private var _controlReads: [(request: USBControlRequest, length: Int)] = []
    private var readStubs: [StubKey: [[UInt8]]] = [:]
    private var bulkChunks: [[UInt8]] = []
    private var repeatingBulkChunk: [UInt8]?
    private var _bulkStreamTerminated = false

    init() {}

    // `NSLock.lock()`/`unlock()` are unavailable from async contexts (they
    // must not straddle a potential suspension point). `withLock` is a
    // synchronous, non-async function, so it may call them directly; async
    // methods below call `withLock` instead of touching `lock` themselves.
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var controlWrites: [(request: USBControlRequest, data: [UInt8])] {
        withLock { _controlWrites }
    }

    var controlReads: [(request: USBControlRequest, length: Int)] {
        withLock { _controlReads }
    }

    /// Queue a canned response for `controlRead` calls matching `(value, index)`.
    /// Responses are served FIFO: the first call to match consumes the first
    /// stub queued for that key, the second call consumes the second, etc.
    func stubRead(value: UInt16, index: UInt16, returns: [UInt8]) {
        let key = StubKey(value: value, index: index)
        withLock { readStubs[key, default: []].append(returns) }
    }

    /// Queue the chunks `bulkStream` will yield, one element per array
    /// supplied, in order.
    func stubBulk(_ chunks: [[UInt8]]) {
        withLock { bulkChunks = chunks }
    }

    /// Queue an unbounded bulk source that keeps yielding `chunk` forever,
    /// stopping only when the consumer's stream is torn down (task
    /// cancellation or iterator termination).
    ///
    /// Use this instead of `stubBulk` for tests that must verify
    /// cancellation actually propagates (e.g. `SDRDevice.stop()`): a finite
    /// `stubBulk` source finishes on its own once its chunks are exhausted,
    /// so a test built on it can pass even if cancellation is never wired
    /// up correctly. A repeating source only stops if something upstream
    /// genuinely cancels/terminates the stream.
    func stubBulkRepeating(_ chunk: [UInt8]) {
        withLock { repeatingBulkChunk = chunk }
    }

    /// `true` once the repeating bulk stream's `onTermination` has fired —
    /// i.e. once whatever is consuming it genuinely stopped (cancellation
    /// or iterator teardown), not merely because canned data ran out.
    var bulkStreamTerminated: Bool {
        withLock { _bulkStreamTerminated }
    }

    private func markBulkStreamTerminated() {
        withLock { _bulkStreamTerminated = true }
    }

    func controlWrite(_ request: USBControlRequest, data: [UInt8]) async throws {
        withLock { _controlWrites.append((request: request, data: data)) }
    }

    func controlRead(_ request: USBControlRequest, length: Int) async throws -> [UInt8] {
        let key = StubKey(value: request.value, index: request.index)
        let stubbed: [UInt8]? = withLock {
            _controlReads.append((request: request, length: length))
            if readStubs[key]?.isEmpty == false {
                return readStubs[key]!.removeFirst()
            }
            return nil
        }
        if let stubbed {
            return stubbed
        }
        if key == Self.demodDummyReadKey {
            return [0x00]
        }
        return [UInt8](repeating: 0, count: length)
    }

    func bulkStream(endpoint: UInt8, transferSize: Int, inFlight: Int) -> AsyncThrowingStream<[UInt8], Error> {
        let (chunks, repeating) = withLock { (bulkChunks, repeatingBulkChunk) }

        if let repeating {
            return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
                let stopped = TerminationFlag()
                let producer = Task {
                    while !stopped.isSet && !Task.isCancelled {
                        continuation.yield(repeating)
                        await Task.yield()
                    }
                }
                // Fires on cancellation of the consuming task or iterator
                // teardown — NOT on `Task.isCancelled` of `producer` (that's a
                // different, unstructured task from whatever is consuming this
                // stream, so it never observes the consumer's cancellation on
                // its own).
                continuation.onTermination = { [weak self] _ in
                    stopped.set()
                    producer.cancel()
                    self?.markBulkStreamTerminated()
                }
            }
        }

        return AsyncThrowingStream { continuation in
            for chunk in chunks {
                continuation.yield(chunk)
            }
            continuation.finish()
        }
    }
}

/// Thread-safe boolean flag bridging an `onTermination` callback (invoked on
/// whatever task/thread notices the consumer stopped) to an independent
/// async producer loop that only has cooperative-cancellation checks.
private final class TerminationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _isSet = false

    var isSet: Bool {
        lock.withLock { _isSet }
    }

    func set() {
        lock.withLock { _isSet = true }
    }
}

extension MockUSBTransport {
    /// Stub the R820T2 tuner status reads (value 0x34, index 0x0600) so setFrequency
    /// sees a locked PLL with vco_fine_tune == 2. Push before calling tune() on a valid freq.
    ///
    /// Bytes are the pre-bit-reversal wire values (the driver bit-reverses on read), so
    /// after reversal the driver observes reg2 = 0x40 (PLL locked) and reg4 = 0x20
    /// (`vco_fine_tune = 2`). FIFO order matters: the 5-byte `vco_fine_tune` read is
    /// consumed first, then the 3-byte PLL-lock read.
    func stubTunerPLLLocked() {
        stubTunerPLLLocked(vcoFineTune: 2)
    }

    /// As `stubTunerPLLLocked()`, but for an arbitrary `vcoFineTune` (0...3), so
    /// tests can drive the `div_num` nudge branches setFrequency takes when the
    /// live status read disagrees with `vco_power_ref` (2): `vcoFineTune < 2`
    /// nudges `div_num` up, `> 2` nudges it down. The reg4 wire byte is derived
    /// by bit-reversing the post-reversal value the driver must observe
    /// (`(vcoFineTune << 4) & 0x30`), since the mock serves pre-bit-reversal
    /// wire bytes; reg2 stays wire `0x02` (post-reversal `0x40`, PLL locked).
    /// FIFO order matches the driver: the 5-byte status read first, then the
    /// 3-byte PLL-lock read.
    func stubTunerPLLLocked(vcoFineTune: UInt8) {
        let wireReg4 = R820T2.bitReverse((vcoFineTune << 4) & 0x30)
        stubRead(value: 0x34, index: 0x0600, returns: [0x00, 0x00, 0x02, 0x00, wireReg4]) // 5-byte: reg4→vco_fine_tune
        stubRead(value: 0x34, index: 0x0600, returns: [0x00, 0x00, 0x02])                 // 3-byte: reg2→locked
    }
}
