import Testing
@testable import CoreSDR

@Test func actorTunesThroughTransport() async throws {
    let m = MockUSBTransport()
    m.stubTunerPLLLocked()
    let dev = SDRDevice(transport: m, info: .init(id: "x", name: "RTL", serial: nil))
    try await dev.open()
    try await dev.tune(to: .mhz(433.92))
    #expect(m.controlWrites.contains { $0.request.index == 0x0610 })   // tuner writes happened
}

@Test func capabilitiesExposeFrequencyRange() {
    let dev = SDRDevice(transport: MockUSBTransport(), info: .init(id: "x", name: "RTL", serial: nil))
    #expect(dev.capabilities.frequencyRange.lowerBound == .mhz(24))
}

/// Non-vacuous: `MockUSBTransport.stubBulkRepeating` yields forever and only
/// stops when its stream is genuinely torn down, so this test can only pass
/// if `stop()` actually cancels the pump task all the way down through
/// `SDRDevice` -> `RTLSDRDevice` -> the transport's bulk stream. (A finite
/// `stubBulk` source would finish on its own regardless of what `stop()`
/// does, making the assertion pass even against a no-op `stop()`.)
@Test func stopEndsActiveSampleStream() async throws {
    let m = MockUSBTransport()
    m.stubBulkRepeating([1, 2, 3, 4])
    m.stubTunerPLLLocked()
    let dev = SDRDevice(transport: m, info: .init(id: "x", name: "RTL", serial: nil))
    try await dev.open()
    try await dev.tune(to: .mhz(433.92))

    let stream = await dev.samples()
    var iterator = stream.makeAsyncIterator()
    // Prove the stream is actually live (not already finished) before stopping.
    _ = try await iterator.next()
    _ = try await iterator.next()

    await dev.stop()

    // Bounded poll for the mock's termination flag, which is only set inside
    // the repeating bulk stream's `onTermination`. If `stop()` doesn't
    // cancel anything, the repeating source keeps running forever and this
    // loop exhausts its budget without hanging the test.
    var terminated = false
    for _ in 0..<1000 {
        if m.bulkStreamTerminated {
            terminated = true
            break
        }
        await Task.yield()
    }
    #expect(terminated)
}

/// A failed hardware operation must not wedge the serial queue: the next
/// operation still runs. The first `tune` fails deterministically (no PLL-lock
/// stub, so the lock check throws); the second, with a stub, must still succeed.
@Test func failedOperationDoesNotBreakSerialChain() async throws {
    let m = MockUSBTransport()
    let dev = SDRDevice(transport: m, info: .init(id: "x", name: "RTL", serial: nil))
    try await dev.open()

    await #expect(throws: SDRError.self) {
        try await dev.tune(to: .mhz(100))
    }

    m.stubTunerPLLLocked()
    try await dev.tune(to: .mhz(433.92))
    #expect(m.controlWrites.contains { $0.request.index == 0x0610 })   // tuner writes happened
}

/// Two concurrent `tune()` calls must not interleave their I2C-repeater
/// brackets. Each `setFrequency` wraps its register programming in exactly one
/// enable (page-1 addr 0x01 = 0x18) / disable (0x10) pair; the serial queue
/// keeps those pairs strictly alternating (E,D,E,D). Reentrant interleaving
/// would nest them (E,E,…), disabling the repeater mid-tune.
@Test func concurrentTunesDoNotInterleaveRepeaterBrackets() async throws {
    let m = MockUSBTransport()
    m.stubTunerPLLLocked()
    m.stubTunerPLLLocked()
    let dev = SDRDevice(transport: m, info: .init(id: "x", name: "RTL", serial: nil))
    try await dev.open()

    // Only interested in the repeater toggles issued by the two tunes.
    let afterOpen = m.controlWrites.count
    async let first: Void = dev.tune(to: .mhz(100))
    async let second: Void = dev.tune(to: .mhz(433.92))
    _ = try await (first, second)

    let repeaterRequest = RTLRegisters.demodWriteRequest(page: 1, addr: 0x01)
    let toggles = m.controlWrites[afterOpen...]
        .filter { $0.request == repeaterRequest }
        .compactMap { $0.data.first }

    #expect(toggles.count == 4)   // two enable/disable pairs, one per tune
    for (i, value) in toggles.enumerated() {
        #expect(value == (i.isMultiple(of: 2) ? 0x18 : 0x10))
    }
}

/// Back-to-back `samples()` with zero grace — no `stop()`, no sleep between the
/// two calls. Covers the actor-level restart plumbing only: cancelling the prior
/// pump task, spinning up a fresh one, and having the new stream deliver. The
/// mock transport hands out independent streams with no shared pipe or
/// `AbortPipe` semantics, so it cannot reproduce the hardware abort-race; that
/// regression is covered by the hardware-gated `streamStopRestartDoesNotCrash`.
@Test func backToBackSamplesRestartYieldsOnFreshStream() async throws {
    let m = MockUSBTransport()
    m.stubBulkRepeating([1, 2, 3, 4])
    m.stubTunerPLLLocked()
    let dev = SDRDevice(transport: m, info: .init(id: "x", name: "RTL", serial: nil))
    try await dev.open()
    try await dev.tune(to: .mhz(433.92))

    let first = await dev.samples()
    var firstIterator = first.makeAsyncIterator()
    _ = try await firstIterator.next()   // prove the first stream is live

    // Immediately restart with zero grace.
    let second = await dev.samples()
    var secondIterator = second.makeAsyncIterator()
    let block = try await secondIterator.next()
    #expect(block?.raw == [1, 2, 3, 4])

    await dev.stop()
}

/// Blocks surfaced through the public `samples()` entry are stamped with a
/// monotonic sequence and the live center frequency.
@Test func samplesStampSequenceAndCenterFrequency() async throws {
    let m = MockUSBTransport()
    m.stubBulkRepeating([10, 20, 30, 40])
    m.stubTunerPLLLocked()
    let dev = SDRDevice(transport: m, info: .init(id: "x", name: "RTL", serial: nil))
    try await dev.open()
    try await dev.tune(to: .mhz(100))

    var blocks: [IQBlock] = []
    for try await b in await dev.samples() {
        blocks.append(b)
        if blocks.count == 2 { break }
    }
    await dev.stop()

    #expect(blocks[0].raw == [10, 20, 30, 40])
    #expect(blocks[0].centerFrequency == .mhz(100))
    // Monotonic sequence stamping. Consecutive values aren't guaranteed: the
    // drop-on-slow `bufferingNewest(1)` policy may skip blocks a slow consumer
    // never read, so the second delivered block only has to be strictly later.
    #expect(blocks[1].sequence > blocks[0].sequence)
}

@Test func samplesAfterStopStartsFreshStream() async throws {
    let m = MockUSBTransport()
    m.stubBulkRepeating([1, 2, 3, 4])
    m.stubTunerPLLLocked()
    let dev = SDRDevice(transport: m, info: .init(id: "x", name: "RTL", serial: nil))
    try await dev.open()
    try await dev.tune(to: .mhz(433.92))

    let firstStream = await dev.samples()
    var firstIterator = firstStream.makeAsyncIterator()
    _ = try await firstIterator.next()
    await dev.stop()

    let secondStream = await dev.samples()
    var secondIterator = secondStream.makeAsyncIterator()
    let block = try await secondIterator.next()
    #expect(block?.raw == [1, 2, 3, 4])

    await dev.stop()
}
