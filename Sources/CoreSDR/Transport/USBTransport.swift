import Foundation

struct USBControlRequest: Sendable, Equatable {
    var requestType: UInt8   // bmRequestType
    var request: UInt8       // bRequest (always 0 for RTL)
    var value: UInt16        // wValue
    var index: UInt16        // wIndex

    init(requestType: UInt8, request: UInt8, value: UInt16, index: UInt16) {
        self.requestType = requestType
        self.request = request
        self.value = value
        self.index = index
    }
}

protocol USBTransport: Sendable {
    func controlWrite(_ request: USBControlRequest, data: [UInt8]) async throws
    func controlRead(_ request: USBControlRequest, length: Int) async throws -> [UInt8]
    // Continuous bulk IN stream from `endpoint`; each element is one transfer's bytes.
    // Cancelling the task/terminating the stream stops the transfers.
    func bulkStream(endpoint: UInt8, transferSize: Int, inFlight: Int) -> AsyncThrowingStream<[UInt8], Error>
}
