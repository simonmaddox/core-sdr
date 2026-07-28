public enum Gain: Sendable, Equatable {
    case automatic
    case manual(dB: Float)
}
