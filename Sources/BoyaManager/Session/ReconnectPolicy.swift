import Foundation

/// Why a session ended. Kept separate from the errors that produced it so the
/// policy — and the popover's "Failed: …" line — can stay readable.
enum FailureKind: Sendable, Equatable {
    /// The interface would not open. `accessoryd` holds it for about a second
    /// after plug-in to run MFi authentication, so this is expected once.
    case claimFailed
    case noSYN
    case noIdentification
    case sessionRefused
    /// Three consecutive request timeouts while ready.
    case unresponsive
    /// RST from the accessory.
    case reset
    /// The interface was terminated under us — the device was unplugged. Never
    /// retried: there is nothing to retry against until it comes back.
    case deviceRemoved
    case transport

    var summary: String {
        switch self {
        case .claimFailed: "could not open the receiver's iAP interface"
        case .noSYN: "the receiver did not start an iAP2 link"
        case .noIdentification: "the receiver did not identify itself"
        case .sessionRefused: "the receiver refused the data session"
        case .unresponsive: "the receiver stopped answering"
        case .reset: "the receiver reset the link"
        case .deviceRemoved: "the receiver was unplugged"
        case .transport: "the connection dropped"
        }
    }
}

enum ReconnectDecision: Sendable, Equatable {
    case retry(after: Duration)
    case giveUp
}

/// The runaway-loop guard. Every failure path in `ReceiverSession` comes
/// through here. The attempt count is reset by the receiver *answering*
/// something, not by the handshake completing — a receiver that connects
/// perfectly and then says nothing would otherwise reset it every cycle and
/// never give up.
///
/// Vocabulary: `maxAttempts` counts retries, so one plug-in event costs at most
/// six connection attempts — the first, then five backed-off retries.
struct ReconnectPolicy: Sendable, Equatable {
    /// How many retries one plug-in event is allowed before the app gives up
    /// and offers a manual "Retry".
    var maxAttempts = 5
    var backoff: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16)]

    /// - Parameter attempt: how many failures have happened this plug-in event,
    ///   1 for the first.
    func decide(attempt: Int, failure _: FailureKind) -> ReconnectDecision {
        guard attempt >= 1 else { return .retry(after: backoff.first ?? .seconds(1)) }
        guard attempt <= maxAttempts, !backoff.isEmpty else { return .giveUp }
        return .retry(after: backoff[min(attempt - 1, backoff.count - 1)])
    }
}
