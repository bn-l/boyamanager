import Foundation

/// A bidirectional byte pipe. `USBTransport` is the real one; the tests
/// substitute a scripted accessory that speaks the same bytes, which is how
/// every layer above this gets exercised without hardware.
protocol ByteTransport: Sendable {
    /// The inbound stream. Call once — the transport owns a single continuation.
    func inbound() async -> AsyncStream<[UInt8]>
    func write(_ bytes: [UInt8]) async throws
    func close() async
    /// True once the device has gone, as opposed to the stream having been
    /// closed from this side. Only the transport can tell those apart, and the
    /// difference is whether the app counts a reconnect attempt and shows a
    /// countdown or simply waits for the device to come back.
    ///
    /// May answer "present" for a moment after a yank — see `USBTransport`.
    var wasTerminated: Bool { get async }
}
