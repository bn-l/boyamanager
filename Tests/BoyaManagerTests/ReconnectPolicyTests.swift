@testable import BoyaManager
import Testing

@Suite("Reconnect policy")
struct ReconnectPolicyTests {
    @Test(
        "Backoff doubles from one second to sixteen",
        arguments: [
            (1, Duration.seconds(1)),
            (2, Duration.seconds(2)),
            (3, Duration.seconds(4)),
            (4, Duration.seconds(8)),
            (5, Duration.seconds(16)),
        ]
    )
    func backoff(attempt: Int, expected: Duration) {
        let policy = ReconnectPolicy()

        let decision = policy.decide(attempt: attempt, failure: .transport)

        #expect(decision == .retry(after: expected))
    }

    @Test("A sixth failure gives up rather than retrying forever", arguments: [6, 7, 50])
    func givesUp(attempt: Int) {
        let policy = ReconnectPolicy()

        let decision = policy.decide(attempt: attempt, failure: .claimFailed)

        #expect(decision == .giveUp)
    }

    @Test("The decision does not depend on which failure it was", arguments: [
        FailureKind.claimFailed, .noSYN, .noIdentification, .sessionRefused, .unresponsive, .reset, .transport,
    ])
    func failureKindDoesNotChangeTheSchedule(failure: FailureKind) {
        let policy = ReconnectPolicy()

        #expect(policy.decide(attempt: 1, failure: failure) == .retry(after: .seconds(1)))
        #expect(policy.decide(attempt: 6, failure: failure) == .giveUp)
    }

    @Test("A shorter schedule gives up as soon as its attempts run out")
    func customPolicy() {
        let policy = ReconnectPolicy(maxAttempts: 2, backoff: [.milliseconds(50), .milliseconds(100)])

        #expect(policy.decide(attempt: 1, failure: .transport) == .retry(after: .milliseconds(50)))
        #expect(policy.decide(attempt: 2, failure: .transport) == .retry(after: .milliseconds(100)))
        #expect(policy.decide(attempt: 3, failure: .transport) == .giveUp)
    }

    @Test("An empty schedule never retries")
    func emptyBackoff() {
        let policy = ReconnectPolicy(maxAttempts: 5, backoff: [])

        #expect(policy.decide(attempt: 1, failure: .transport) == .giveUp)
    }

    @Test("Every failure kind has a summary the popover can show")
    func summaries() {
        let kinds: [FailureKind] = [.claimFailed, .noSYN, .noIdentification, .sessionRefused, .unresponsive, .reset, .transport]

        for kind in kinds {
            #expect(!kind.summary.isEmpty)
        }
        #expect(Set(kinds.map(\.summary)).count == kinds.count, "summaries must be distinguishable")
    }
}
