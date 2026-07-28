public struct SDRDeviceInfo: Sendable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let serial: String?
    public init(id: String, name: String, serial: String?) {
        self.id = id; self.name = name; self.serial = serial
    }
}
