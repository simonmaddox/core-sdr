import CoreSDR
import Foundation

/// `coresdr-demo` — end-to-end smoke test for the CoreSDR stack against a real
/// RTL-SDR dongle.
///
/// Usage:
///   coresdr-demo                 List attached devices (id / name / serial).
///   coresdr-demo --tune <mhz>    Open the first device, tune to <mhz>, stream
///                                for ~1 s, and print a crude power meter
///                                (mean IQ magnitude) for the band.

/// Mean magnitude of the interleaved IQ samples in a block: for each complex
/// pair (I, Q) in `normalized()` output, `sqrt(I*I + Q*Q)`, averaged.
func meanMagnitude(_ block: IQBlock) -> Double {
    let samples = block.normalized()
    guard samples.count >= 2 else { return 0 }
    var sum = 0.0
    var pairs = 0
    var index = 0
    while index + 1 < samples.count {
        let i = Double(samples[index])
        let q = Double(samples[index + 1])
        sum += (i * i + q * q).squareRoot()
        pairs += 1
        index += 2
    }
    return pairs == 0 ? 0 : sum / Double(pairs)
}

func listDevices() async throws {
    let devices = try await SDRDevice.discover()
    if devices.isEmpty {
        print("no devices")
        return
    }
    print("Discovered \(devices.count) device(s):")
    for device in devices {
        print("  id:     \(device.id)")
        print("  name:   \(device.name)")
        print("  serial: \(device.serial ?? "(none)")")
        print("")
    }
}

func tune(megahertz: Double) async throws {
    let frequency = Frequency.mhz(megahertz)
    print("Opening default device...")
    let device = try await SDRDevice.default

    print(String(format: "Tuning to %.3f MHz, 2.4 MS/s, automatic gain...", megahertz))
    try await device.tune(to: frequency)
    try await device.setSampleRate(.rate2_4M)
    try await device.setGain(.automatic)

    print("Streaming for ~1 second...")
    var magnitudeSum = 0.0
    var blockCount = 0
    let deadline = Date().addingTimeInterval(1.0)
    let stream = await device.samples()
    for try await block in stream {
        magnitudeSum += meanMagnitude(block)
        blockCount += 1
        if Date() >= deadline { break }
    }
    await device.stop()

    guard blockCount > 0 else {
        print("No samples received.")
        return
    }
    let power = magnitudeSum / Double(blockCount)
    let bars = Int((power * 60).rounded())
    let meter = String(repeating: "#", count: max(0, min(bars, 60)))
    print(String(format: "Blocks: %d   Power (mean IQ magnitude): %.4f", blockCount, power))
    print("  [\(meter)]")
}

// MARK: - Entry point

let arguments = CommandLine.arguments
if let tuneIndex = arguments.firstIndex(of: "--tune") {
    guard tuneIndex + 1 < arguments.count, let mhz = Double(arguments[tuneIndex + 1]) else {
        print("usage: coresdr-demo --tune <mhz>")
        exit(2)
    }
    do {
        try await tune(megahertz: mhz)
    } catch {
        print("error: \(error)")
        exit(1)
    }
} else {
    do {
        try await listDevices()
    } catch {
        print("error: \(error)")
        exit(1)
    }
}
