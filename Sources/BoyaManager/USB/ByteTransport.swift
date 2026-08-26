import Foundation

/// A bidirectional byte pipe. `USBTransport` is the real one; the tests
/// substitute a scripted accessory that speaks the same bytes, which is how
/// every layer above this gets exercised without hardware.
protocol ByteTransport: Sendable {
    /// The inbound stream. Call once — the transport owns a single continuation.
    func inbound() async -> AsyncStream<[UInt8]>
    func write(_ bytes: [UInt8]) async throws
    func close() async
}
