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
