import AppKit
import Foundation
import Testing
@testable import BoyaManager

/// The quit path. It used to block the main thread on a semaphore while the
/// work it waited for was MainActor-isolated, so the shutdown never ran, the
/// receiver was never told the session was over, and every quit took the full
/// 1.5 s timeout.
@Suite("Application termination")
@MainActor
struct AppDelegateTests {
    @Test("Quitting tells the receiver the session is over before the app exits")
    func terminationRunsTheShutdown() async throws {
        let accessory = FakeAccessory()
        let harness = await SessionHarness(makeLink: { IAP2Link(transport: accessory, initialSequence: 0x40) })
        harness.send(.arrived)
        #expect(await harness.recorder.wait { $0.contains { if case .state(.ready) = $0 { true } else { false } } })
        let delegate = AppDelegate()
        let reply = Reply()
        delegate.shutdown = { await harness.finish() }
        delegate.replyToTermination = { answer in Task { await reply.record(answer) } }

        let started = ContinuousClock.now
        let decision = delegate.applicationShouldTerminate(NSApplication.shared)

        #expect(decision == .terminateLater, "quitting must wait for the receiver to be told")
        #expect(await reply.wait() == true)
        let elapsed = ContinuousClock.now - started
        #expect(elapsed < .seconds(1.5), "the quit took \(elapsed.milliseconds)ms — it should not be waiting on a timeout")
        #expect(await accessory.stopSessionCount == 1, "StopExternalAccessoryProtocolSession never reached the receiver")
    }

    @Test("A second instance quits at once rather than waiting on a session it never opened")
    func duplicateInstanceQuitsAtOnce() async throws {
        let delegate = AppDelegate()
        let ran = Reply()
        delegate.isDuplicateInstance = true
        delegate.shutdown = { await ran.record(true) }

        let decision = delegate.applicationShouldTerminate(NSApplication.shared)

        #expect(decision == .terminateNow)
        #expect(await ran.count == 0, "a duplicate instance has no session to shut down")
    }

    @Test("A shutdown that wedges still lets the app quit")
    func wedgedShutdownStillQuits() async throws {
        let delegate = AppDelegate()
        let reply = Reply()
        delegate.terminationTimeout = .milliseconds(200)
        delegate.shutdown = { try? await Task.sleep(for: .seconds(30)) }
        delegate.replyToTermination = { answer in Task { await reply.record(answer) } }

        let started = ContinuousClock.now
        _ = delegate.applicationShouldTerminate(NSApplication.shared)

        #expect(await reply.wait() == true)
        #expect(ContinuousClock.now - started < .seconds(2))
    }
}

/// Captures the single answer AppKit is given, from whichever task produces it.
private actor Reply {
    private var answer: Bool?
    private(set) var count = 0

    func record(_ answer: Bool) {
        self.answer = answer
        count += 1
    }

    func wait(timeout: Duration = .seconds(5)) async -> Bool? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let answer { return answer }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return answer
    }
}
