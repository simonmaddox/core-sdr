import IOKit

/// Errors surfaced by the CoreSDR public API.
///
/// USB failures carry the underlying `IOReturn` code (see `.usb`) so callers can
/// distinguish a stall from a sandbox access denial from a short read
/// programmatically, not just by string-matching a message. Disconnect-class
/// `IOReturn`s (device pulled, not responding, not attached) are folded into the
/// dedicated `.deviceDisconnected` case on every path — control and streaming
/// alike — so apps can react to a hot-unplug uniformly.
public enum SDRError: Error, Sendable {
    case deviceNotFound
    case tuningOutOfRange(Frequency)
    case unsupportedSampleRate(SampleRate)
    case deviceDisconnected
    /// A USB-level failure. `code` is the raw IOKit `IOReturn` (or an HRESULT
    /// from a COM `QueryInterface`); `message` is a human-readable description
    /// that already embeds the code in hex.
    case usb(code: IOReturn, message: String)
}

extension SDRError {
    /// Builds the most specific error for an IOKit `IOReturn` (or COM `HRESULT`)
    /// failure. Disconnect-class codes collapse to `.deviceDisconnected`; every
    /// other code is retained verbatim in `.usb` for programmatic inspection,
    /// with `context` and the hex code composed into the message.
    static func usb(_ code: IOReturn, _ context: String) -> SDRError {
        switch code {
        case kIOReturnNoDevice, kIOReturnNotResponding, kIOReturnNotAttached:
            return .deviceDisconnected
        default:
            return .usb(code: code, message: "\(context) (\(hexDescription(code)))")
        }
    }

    /// A USB/protocol failure with no meaningful `IOReturn` (a logic or
    /// data-integrity violation, e.g. a short control read). Recorded under the
    /// generic `kIOReturnError` code.
    static func usb(_ message: String) -> SDRError {
        .usb(code: kIOReturnError, message: message)
    }

    /// Human-readable hex rendering of an `IOReturn`/`HRESULT` for messages.
    static func hexDescription(_ code: IOReturn) -> String {
        "IOReturn 0x" + String(format: "%08x", UInt32(bitPattern: code))
    }
}
