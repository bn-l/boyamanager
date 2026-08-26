import Foundation
import Testing
@testable import BoyaManager

@Suite("Receiver session, end to end against a scripted accessory")
@MainActor
struct ReceiverSessionTests {
    private func harness(
        _ options: FakeAccessory.Options = .init(),
        policy: ReconnectPolicy = ReconnectPolicy(),
        timings: ReceiverSession.Timings = ReceiverSession.Timings()
    ) async -> (SessionHarness, FakeAccessory) {
        let accessory = FakeAccessory(options: options)
        let harness = await SessionHarness(
            makeLink: { IAP2Link(transport: accessory, initialSequence: 0x40) },
            policy: policy,
            timings: timings
        )
        return (harness, accessory)
    }

    @Test("An arriving device is taken all the way to ready")
    func reachesReady() async throws {
        let (harness, _) = await harness()
        defer { Task { await harness.finish() } }

        harness.send(.arrived)

        #expect(await harness.recorder.wait { $0.contains { if case .state(.ready) = $0 { true } else { false } } })
        let identity = await harness.recorder.identities.first
        #expect(identity?.serial == "CFD7387E79")
        #expect(await harness.recorder.connectAttempts == [1])
    }

    @Test("Device heartbeats are answered, addressed back to the sender with src and dst swapped")
    func answersHeartbeats() async throws {
        let (harness, accessory) = await harness()
        defer { Task { await harness.finish() } }

        harness.send(.arrived)
        #expect(await harness.recorder.wait { !$0.isEmpty && $0.contains { if case .snapshot = $0 { true } else { false } } })

        let replies = await accessory.hostHeartbeatRepliesToDevice
        #expect(!replies.isEmpty, "the receiver goes mute if its heartbeats are not answered")
        for reply in replies {
            #expect(reply.src == CFDLink.hostNode)
            #expect(reply.dst == CFDLink.deviceNode)
        }
    }

    @Test("Frames the router hands back are ignored — the host never answers its own heartbeats")
    func ignoresEchoedFrames() async throws {
        let (harness, accessory) = await harness(.init(echoesHostFrames: true))
        defer { Task { await harness.finish() } }

        harness.send(.arrived)
        #expect(await harness.recorder.wait { $0.contains { if case .snapshot = $0 { true } else { false } } })
        try await Task.sleep(for: .milliseconds(300))

        let frames = await accessory.hostFrames
        #expect(!frames.isEmpty)
        // Answering an echoed frame (src = 2) would produce one addressed back
        // to ourselves. Over iAP2 that recursed forever.
        #expect(frames.allSatisfy { $0.dst == CFDLink.deviceNode },
                "a frame addressed to the host means an echo got answered")
    }

    @Test("A poll publishes the receiver's whole attribute dump")
    func publishesSnapshot() async throws {
        let (harness, _) = await harness()
        defer { Task { await harness.finish() } }

        harness.send(.arrived)
        #expect(await harness.recorder.wait { $0.contains { if case .snapshot = $0 { true } else { false } } })

        let snapshot = try #require(await harness.recorder.snapshots.first)
        #expect(snapshot.values.count == 24)
        #expect(snapshot.byte(.noiseCancellation) == 2)
        #expect(snapshot.tx2.isOnline)
        #expect(!snapshot.tx1.isOnline)
    }

    @Test("A write is confirmed by reading it back, not by assuming it took")
    func writeReadsBack() async throws {
        let (harness, accessory) = await harness()
        defer { Task { await harness.finish() } }
        harness.send(.arrived)
        #expect(await harness.recorder.wait { $0.contains { if case .state(.ready) = $0 { true } else { false } } })

        await harness.session.set(.noiseCancellation, to: 1)

        #expect(await harness.recorder.wait { $0.contains { if case .writeResult = $0 { true } else { false } } })
        let results = await harness.recorder.writeResults
        let result = try #require(results.first { $0.attr == .noiseCancellation })
        #expect(try result.result.get() == 1)
        #expect(await accessory.attributes[Attr.noiseCancellation.rawValue] == 1)
        let frames = await accessory.hostFrames
        #expect(frames.contains { $0.message == CFDMessage.setAttribute.rawValue })
        #expect(frames.contains { $0.message == CFDMessage.getAttribute.rawValue })
    }

    @Test("A value outside the device's range is refused before it reaches the wire")
    func rejectsOutOfRange() async throws {
        let (harness, accessory) = await harness()
        defer { Task { await harness.finish() } }
        harness.send(.arrived)
        #expect(await harness.recorder.wait { $0.contains { if case .state(.ready) = $0 { true } else { false } } })

        await harness.session.set(.rxGain, to: 9)

        #expect(await harness.recorder.wait { $0.contains { if case .writeResult = $0 { true } else { false } } })
        let result = try #require(await harness.recorder.writeResults.first { $0.attr == .rxGain })
        #expect(throws: SessionError.outOfRange(9, 1...6)) { try result.result.get() }
        #expect(await accessory.attributes[Attr.rxGain.rawValue] == 4, "the device must not have been written to")
    }

    @Test("A risky attribute cannot be written through the ordinary path")
    func refusesRiskyThroughSet() async throws {
        let (harness, accessory) = await harness()
        defer { Task { await harness.finish() } }
        harness.send(.arrived)
        #expect(await harness.recorder.wait { $0.contains { if case .state(.ready) = $0 { true } else { false } } })

        await harness.session.set(.rxReset, to: 1)

        #expect(await harness.recorder.wait { $0.contains { if case .writeResult = $0 { true } else { false } } })
        let result = try #require(await harness.recorder.writeResults.first { $0.attr == .rxReset })
        #expect(throws: SessionError.riskyWriteRefused) { try result.result.get() }
        let frames = await accessory.hostFrames
        #expect(!frames.contains { $0.message == CFDMessage.setAttribute.rawValue })
    }

    @Test("The advanced path can write a risky attribute")
    func riskyWriteGoesThrough() async throws {
        let (harness, accessory) = await harness()
        defer { Task { await harness.finish() } }
        harness.send(.arrived)
        #expect(await harness.recorder.wait { $0.contains { if case .state(.ready) = $0 { true } else { false } } })

        await harness.session.setRisky(.rxSpeaker, to: 1)

        #expect(await accessory.attributes[Attr.rxSpeaker.rawValue] == 1)
    }

    /// The receiver really does go quiet for a second or so at a time, and it
    /// acknowledges by piggybacking on its own traffic rather than the 255 ms
    /// it advertises. Insisting on an acknowledgement for every heartbeat used
    /// to tear the session down when that happened.
    @Test("A receiver that goes quiet for a moment does not lose the session")
    func lazyAcknowledgementsDoNotDropTheSession() async throws {
        let (harness, accessory) = await harness()
        defer { Task { await harness.finish() } }
        harness.send(.arrived)
        #expect(await harness.recorder.wait { $0.contains { if case .snapshot = $0 { true } else { false } } })

        // Long enough that insisting on an acknowledgement would exhaust the
        // link's three retries and report a dead transport.
        await accessory.goQuiet()
        try await Task.sleep(for: .milliseconds(3500))
        await accessory.resume()

        #expect(await harness.recorder.connectAttempts == [1], "a quiet moment must not force a reconnect")
        let snapshotsBefore = await harness.recorder.snapshots.count
        #expect(await harness.recorder.wait(timeout: .seconds(15)) { events in
            events.count { if case .snapshot = $0 { true } else { false } } > snapshotsBefore
        }, "polling should pick straight back up")
        #expect(await harness.recorder.states.last == .ready)
    }

    @Test("Three request timeouts are treated as a dead link and trigger a reconnect")
    func threeTimeoutsReconnect() async throws {
        let (harness, _) = await harness(.init(answersRequests: false))
        defer { Task { await harness.finish() } }

        harness.send(.arrived)

        #expect(await harness.recorder.wait(timeout: .seconds(20)) { events in
            events.compactMap { if case .state(let state) = $0 { state } else { nil } }
                .compactMap { if case .connecting(let attempt) = $0 { attempt } else { nil } }
                .contains(2)
        }, "an unresponsive receiver should be reconnected to")
        #expect(await harness.recorder.reachedReady)
    }

    @Test("Reconnection stops after five attempts, backing off 1/2/4/8/16 seconds")
    func backoffThenGiveUp() async throws {
        struct Unplugged: Error {}
        let clock = Clock()
        let harness = await SessionHarness(
            makeLink: { throw Unplugged() },
            timings: ReceiverSession.Timings(deviceDebounce: .milliseconds(50)),
            clock: clock
        )
        defer { Task { await harness.finish() } }

        harness.send(.arrived)

        #expect(await harness.recorder.wait(timeout: .seconds(30)) { events in
            events.contains { if case .state(.failed) = $0 { true } else { false } }
        }, "the session must give up rather than retry forever")
        #expect(await harness.recorder.connectAttempts == [1, 2, 3, 4, 5, 6])
        #expect(await clock.requested == [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16)])
    }

    @Test("A manual retry after giving up starts a fresh attempt")
    func manualRetry() async throws {
        struct Unplugged: Error {}
        let attempts = Counter()
        let accessory = FakeAccessory()
        let harness = await SessionHarness(
            makeLink: {
                // Fail the first six attempts so the policy gives up, then work.
                if await attempts.next() <= 6 { throw Unplugged() }
                return IAP2Link(transport: accessory, initialSequence: 0x40)
            },
            timings: ReceiverSession.Timings(deviceDebounce: .milliseconds(50))
        )
        defer { Task { await harness.finish() } }
        harness.send(.arrived)
        #expect(await harness.recorder.wait(timeout: .seconds(30)) { events in
            events.contains { if case .state(.failed) = $0 { true } else { false } }
        })

        await harness.session.retryNow()

        #expect(await harness.recorder.wait(timeout: .seconds(20)) { events in
            events.contains { if case .state(.ready) = $0 { true } else { false } }
        })
    }

    @Test("A removal immediately followed by an arrival is one event, not a reconnect")
    func debouncesSelfReEnumeration() async throws {
        let (harness, _) = await harness(timings: ReceiverSession.Timings(deviceDebounce: .milliseconds(500)))
        defer { Task { await harness.finish() } }
        harness.send(.arrived)
        #expect(await harness.recorder.wait { $0.contains { if case .state(.ready) = $0 { true } else { false } } })

        harness.send(.removed)
        harness.send(.arrived)
        try await Task.sleep(for: .milliseconds(400))

        #expect(await harness.recorder.connectAttempts == [1], "the receiver re-enumerating itself must not restart the session")
        #expect(await harness.recorder.states.last == .ready)
    }

    @Test("A real removal drops the session and goes back to idle")
    func removalGoesIdle() async throws {
        let (harness, _) = await harness(timings: ReceiverSession.Timings(deviceDebounce: .milliseconds(50)))
        defer { Task { await harness.finish() } }
        harness.send(.arrived)
        #expect(await harness.recorder.wait { $0.contains { if case .state(.ready) = $0 { true } else { false } } })

        harness.send(.removed)

        #expect(await harness.recorder.wait { $0.contains { if case .state(.idle) = $0 { true } else { false } } })
    }

    @Test("Quitting tells the receiver to stop the session, exactly once")
    func shutdownStopsSessionOnce() async throws {
        let (harness, accessory) = await harness()
        harness.send(.arrived)
        #expect(await harness.recorder.wait { $0.contains { if case .state(.ready) = $0 { true } else { false } } })

        await harness.finish()
        try await Task.sleep(for: .milliseconds(200))

        #expect(await accessory.stopSessionCount == 1)
    }

    @Test("A write attempted while disconnected fails instead of hanging")
    func writeWhileDisconnected() async throws {
        let (harness, _) = await harness()
        defer { Task { await harness.finish() } }

        await harness.session.set(.noiseCancellation, to: 1)

        #expect(await harness.recorder.wait { $0.contains { if case .writeResult = $0 { true } else { false } } })
        let result = try #require(await harness.recorder.writeResults.first)
        #expect(throws: SessionError.notReady) { try result.result.get() }
    }
}

/// Counts calls, for makeLink factories that need to fail a fixed number of times.
actor Counter {
    private var count = 0
    func next() -> Int {
        count += 1
        return count
    }
}
