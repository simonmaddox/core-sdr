public enum SDRError: Error, Sendable {
    case deviceNotFound
    case unsupportedDevice
    case tuningOutOfRange(Frequency)
    case unsupportedSampleRate(SampleRate)
    case deviceDisconnected
    case notStreaming
    case usb(String)
}
