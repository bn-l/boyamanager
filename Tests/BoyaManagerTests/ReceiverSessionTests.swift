import Foundation
import Testing
@testable import BoyaManager

@Suite("Receiver session, end to end against a scripted accessory")
@MainActor
struct ReceiverSessionTests {
    /// Teardown is awaited rather than deferred into a detached task, so one
    /// test's session, fake and timers are finished before the next starts.
    /// The link runs on the same compressed clock as the session.
    private func withHarness(
        _ options: FakeAccessory.Options = .init(),
        policy: ReconnectPolicy = ReconnectPolicy(),
        timings: ReceiverSession.Timings = ReceiverSession.Timings(),
        pollInterval: Duration = .seconds(1),
        clock: Clock = Clock(),
        linkSleeper: @escaping IAP2Link.Sleeper = Clock.linkSleeper,
        _ body: (SessionHarness, FakeAccessory) async throws -> Void
    ) async throws {
        let accessory = FakeAccessory(options: options)
        let harness = await SessionHarness(
            makeLink: { IAP2Link(transport: accessory, initialSequence: 0x40, sleeper: linkSleeper) },
            policy: policy,
            timings: timings,
            pollInterval: pollInterval,
            clock: clock
        )
        do {
            try await body(harness, accessory)
        } catch {
            await harness.finish()
            throw error
        }
        await harness.finish()
    }

    private nonisolated static func reachedReady(_ events: [SessionEvent]) -> Bool {
        events.contains { if case .state(.ready) = $0 { true } else { false } }
    }

    private nonisolated static func sawSnapshot(_ events: [SessionEvent]) -> Bool {
        events.contains { if case .snapshot = $0 { true } else { false } }
    }

    @Test("An arriving device is taken all the way to ready")
    func reachesReady() async throws {
        try await withHarness { harness, _ in
            harness.send(.arrived)

            #expect(await harness.recorder.wait(until: Self.reachedReady))
            let identity = await harness.recorder.identities.first
            #expect(identity?.serial == "CFD7387E79")
            #expect(await harness.recorder.connectAttempts == [1])
        }
    }

    @Test("Device heartbeats are answered, addressed back to the node that sent them")
    func answersHeartbeats() async throws {
        try await withHarness { harness, accessory in
            harness.send(.arrived)
            #expect(await harness.recorder.wait(until: Self.sawSnapshot))

            let replies = await accessory.hostHeartbeatRepliesToDevice
            #expect(!replies.isEmpty, "the receiver goes mute if its heartbeats are not answered")
            for reply in replies {
                #expect(reply.src == CFDLink.hostNode)
                #expect(reply.dst == CFDLink.deviceNode)
                #expect(reply.node == Fixtures.heartbeatingNode, "a reply carries back the handle of whatever beat at us")
            }
        }
    }

    /// `CFDLink.heartbeatPayload` promises the host's uptime in milliseconds.
    /// Computing it as `seconds * 1000` quantised every beat inside the same
    /// second to the same value.
    @Test("Consecutive heartbeats carry a tick that actually moves")
    func heartbeatTickAdvances() async throws {
        try await withHarness { harness, accessory in
            harness.send(.arrived)
            #expect(await harness.recorder.wait(until: Self.sawSnapshot))

            let beats = await accessory.hostFrames.filter {
                $0.message == CFDMessage.heartbeat.rawValue && $0.node == .broadcast && $0.payload.count >= 13
            }
            #expect(beats.count >= 2, "only \(beats.count) host heartbeats — nothing to compare")
            let ticks = beats.map { frame in
                frame.payload[6...9].reversed().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            }
            #expect(Set(ticks).count == ticks.count, "beats 500ms apart carried the same tick: \(ticks)")
        }
    }

    @Test("Frames the router hands back are ignored — the host never answers its own heartbeats")
    func ignoresEchoedFrames() async throws {
        try await withHarness(.init(echoesHostFrames: true)) { harness, accessory in
            harness.send(.arrived)
            #expect(await harness.recorder.wait(until: Self.sawSnapshot))
            try await Task.sleep(for: .milliseconds(300))

            let frames = await accessory.hostFrames
            #expect(!frames.isEmpty)
            // Answering an echoed frame (src = 2) would produce one addressed
            // back to ourselves. Over iAP2 that recursed forever.
            #expect(frames.allSatisfy { $0.dst == CFDLink.deviceNode },
                    "a frame addressed to the host means an echo got answered")
        }
    }

    @Test("A poll publishes the receiver's whole attribute dump")
    func publishesSnapshot() async throws {
        try await withHarness { harness, _ in
            harness.send(.arrived)

            let snapshot = try #require(await harness.recorder.waitForSnapshot())
            #expect(snapshot.values.count == 24)
            #expect(snapshot.byte(.noiseCancellation) == 2)
            #expect(snapshot.tx2.isOnline)
            #expect(!snapshot.tx1.isOnline)
        }
    }

    /// The receiver frequently answers a request before the link layer
    /// acknowledges the packet that carried it. Registering the pending request
    /// after the send returned dropped that reply, and every poll timed out.
    /// Driven through the link seam rather than the scripted accessory: the
    /// accessory serialises everything behind its own acknowledgements, so
    /// which of the two orderings comes out is a coin toss there. `EagerLink`
    /// answers *inside* `sendEA`, which is the ordering the real receiver
    /// produces and the one the bug depended on.
    @Test("A reply that lands before the acknowledgement is still matched to its request")
    func replyBeforeAcknowledgement() async throws {
        let link = EagerLink()
        let harness = await SessionHarness(makeLink: { link })

        harness.send(.arrived)

        let snapshot = try #require(
            await harness.recorder.waitForSnapshot(timeout: .seconds(10)),
            "no snapshot: a reply that overtook its acknowledgement was dropped"
        )
        #expect(snapshot.values.count == 24)
        await harness.finish()
    }

    @Test("A write is confirmed by reading it back, not by assuming it took")
    func writeReadsBack() async throws {
        try await withHarness { harness, accessory in
            harness.send(.arrived)
            #expect(await harness.recorder.wait(until: Self.reachedReady))

            await harness.session.set(.noiseCancellation, to: 1)

            let result = try #require(await harness.recorder.writeResult(for: .noiseCancellation))
            #expect(try result.get() == 1)
            #expect(await accessory.attributes[Attr.noiseCancellation.rawValue] == 1)
            let frames = await accessory.hostFrames
            #expect(frames.contains { $0.message == CFDMessage.setAttribute.rawValue })
            #expect(frames.contains { $0.message == CFDMessage.getAttribute.rawValue })
        }
    }

    @Test("A value outside the device's range is refused before it reaches the wire")
    func rejectsOutOfRange() async throws {
        try await withHarness { harness, accessory in
            harness.send(.arrived)
            #expect(await harness.recorder.wait(until: Self.reachedReady))

            await harness.session.set(.rxGain, to: 9)

            let result = try #require(await harness.recorder.writeResult(for: .rxGain))
            #expect(throws: SessionError.outOfRange(9, 1...6)) { try result.get() }
            #expect(await accessory.attributes[Attr.rxGain.rawValue] == 4, "the device must not have been written to")
        }
    }

    @Test("A risky attribute cannot be written through the ordinary path")
    func refusesRiskyThroughSet() async throws {
        try await withHarness { harness, accessory in
            harness.send(.arrived)
            #expect(await harness.recorder.wait(until: Self.reachedReady))

            await harness.session.set(.rxReset, to: 1)

            let result = try #require(await harness.recorder.writeResult(for: .rxReset))
            #expect(throws: SessionError.riskyWriteRefused) { try result.get() }
            let frames = await accessory.hostFrames
            #expect(!frames.contains { $0.message == CFDMessage.setAttribute.rawValue })
        }
    }

    @Test("The advanced path can write a risky attribute")
    func riskyWriteGoesThrough() async throws {
        try await withHarness { harness, accessory in
            harness.send(.arrived)
            #expect(await harness.recorder.wait(until: Self.reachedReady))

            await harness.session.setRisky(.rxSpeaker, to: 1)

            let result = try #require(await harness.recorder.writeResult(for: .rxSpeaker))
            #expect(try result.get() == 1)
            #expect(await accessory.attributes[Attr.rxSpeaker.rawValue] == 1)
        }
    }

    /// `rx_speaker` restarts the receiver and `rx_reset` wipes it, so the link
    /// dies between the command and any read-back. Putting them through the
    /// ordinary set-then-read-back transaction reported a *successful* action
    /// as "Receiver Speaker Mode did not answer."
    @Test("An action that takes the link with it is reported as done, not as a timeout", arguments: [
        Attr.rxSpeaker, Attr.rxReset,
    ])
    func riskyActionSurvivesTheRestart(attr: Attr) async throws {
        let options = FakeAccessory.Options(restartsOnSpeakerWrite: true, resetsOnFactoryReset: true)
        try await withHarness(options) { harness, accessory in
            harness.send(.arrived)
            #expect(await harness.recorder.wait(until: Self.reachedReady))

            await harness.session.setRisky(attr, to: 1)

            let result = try #require(await harness.recorder.writeResult(for: attr))
            #expect(try result.get() == 1, "the receiver restarting is the action working, not a failure")
            #expect(await accessory.attributes[attr.rawValue] == 1)
        }
    }

    /// The receiver really does go quiet for a second or so at a time, and it
    /// acknowledges by piggybacking on its own traffic rather than the 255 ms
    /// it advertises. Insisting on an acknowledgement for every heartbeat used
    /// to tear the session down when that happened.
    @Test("A receiver that goes quiet for a moment does not lose the session")
    func lazyAcknowledgementsDoNotDropTheSession() async throws {
        try await withHarness { harness, accessory in
            harness.send(.arrived)
            #expect(await harness.recorder.wait(until: Self.sawSnapshot))

            // 3.5 seconds of session time — long enough that insisting on an
            // acknowledgement would exhaust the link's three retries.
            await accessory.goQuiet()
            try await Task.sleep(for: .milliseconds(350))
            await accessory.resume()

            #expect(await harness.recorder.connectAttempts == [1], "a quiet moment must not force a reconnect")
            let snapshotsBefore = await harness.recorder.snapshots.count
            #expect(await harness.recorder.wait(timeout: .seconds(15)) { events in
                events.count { if case .snapshot = $0 { true } else { false } } > snapshotsBefore
            }, "polling should pick straight back up")
            #expect(await harness.recorder.states.last == .ready)
        }
    }

    @Test("Three request timeouts are treated as a dead link and trigger a reconnect")
    func threeTimeoutsReconnect() async throws {
        try await withHarness(.init(answersRequests: false)) { harness, _ in
            harness.send(.arrived)

            #expect(await harness.recorder.wait(timeout: .seconds(30)) { events in
                events.compactMap { if case .state(let state) = $0 { state } else { nil } }
                    .compactMap { if case .connecting(let attempt) = $0 { attempt } else { nil } }
                    .contains(2)
            }, "an unresponsive receiver should be reconnected to")
            #expect(await harness.recorder.reachedReady)
        }
    }

    /// The reconnect bound used to be reset the moment the handshake completed.
    /// A receiver that handshakes perfectly and then answers nothing therefore
    /// cycled ready → three timeouts → retry → ready → … forever, at roughly
    /// seventeen seconds a lap, which is precisely the runaway loop the bound
    /// exists to stop.
    @Test("A receiver that handshakes but never answers still gives up")
    func unresponsiveReceiverIsBounded() async throws {
        let clock = Clock()
        // Everything but the backoff is pushed below the clock's noise floor,
        // so `requested` is the backoff schedule and nothing else.
        try await withHarness(
            .init(answersRequests: false),
            timings: ReceiverSession.Timings(request: .milliseconds(400), deviceDebounce: .milliseconds(50)),
            pollInterval: .milliseconds(200),
            clock: clock
        ) { harness, _ in
            harness.send(.arrived)

            #expect(await harness.recorder.wait(timeout: .seconds(60)) { events in
                events.contains { if case .state(.failed) = $0 { true } else { false } }
            }, "a handshake that always works and a link that never answers must still be bounded")
            #expect(await harness.recorder.connectAttempts == [1, 2, 3, 4, 5, 6])
            #expect(await clock.requested == [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16)])
        }
    }

    @Test("Reconnection stops after five retries, backing off 1/2/4/8/16 seconds")
    func backoffThenGiveUp() async throws {
        struct Unplugged: Error {}
        let clock = Clock()
        let harness = await SessionHarness(
            makeLink: { throw Unplugged() },
            timings: ReceiverSession.Timings(deviceDebounce: .milliseconds(50)),
            clock: clock
        )

        harness.send(.arrived)

        #expect(await harness.recorder.wait(timeout: .seconds(30)) { events in
            events.contains { if case .state(.failed) = $0 { true } else { false } }
        }, "the session must give up rather than retry forever")
        #expect(await harness.recorder.connectAttempts == [1, 2, 3, 4, 5, 6])
        #expect(await clock.requested == [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16)])
        await harness.finish()
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
                return IAP2Link(transport: accessory, initialSequence: 0x40, sleeper: Clock.linkSleeper)
            },
            timings: ReceiverSession.Timings(deviceDebounce: .milliseconds(50))
        )
        harness.send(.arrived)
        #expect(await harness.recorder.wait(timeout: .seconds(30)) { events in
            events.contains { if case .state(.failed) = $0 { true } else { false } }
        })

        await harness.session.retryNow()

        #expect(await harness.recorder.wait(timeout: .seconds(20), until: Self.reachedReady))
        await harness.finish()
    }

    /// The debounce only suppresses the `.idle` publish: the transport dies
    /// with the interface, so a self re-enumeration still costs the session it
    /// was in. What it buys is that the *user* sees one continuous connection
    /// rather than a disconnect.
    @Test("A removal immediately followed by an arrival does not show up as a disconnection")
    func debouncesSelfReEnumeration() async throws {
        try await withHarness(timings: ReceiverSession.Timings(deviceDebounce: .milliseconds(500))) { harness, _ in
            harness.send(.arrived)
            #expect(await harness.recorder.wait(until: Self.reachedReady))

            harness.send(.removed)
            harness.send(.arrived)
            try await Task.sleep(for: .milliseconds(400))

            #expect(await harness.recorder.connectAttempts == [1], "the receiver re-enumerating itself must not restart the session")
            #expect(await harness.recorder.states.last == .ready)
        }
    }

    @Test("A real removal drops the session and goes back to idle")
    func removalGoesIdle() async throws {
        try await withHarness(timings: ReceiverSession.Timings(deviceDebounce: .milliseconds(50))) { harness, _ in
            harness.send(.arrived)
            #expect(await harness.recorder.wait(until: Self.reachedReady))

            harness.send(.removed)

            #expect(await harness.recorder.wait { $0.contains { if case .state(.idle) = $0 { true } else { false } } })
        }
    }

    /// The IOKit removal is a second behind its debounce, so the transport is
    /// what tells us first. Treating that as a generic dropped connection put
    /// a "retrying in 1s" countdown on screen for a device that is not there,
    /// and burned a reconnect attempt on every unplug.
    @Test("Unplugging goes straight to idle, with no retry countdown in between")
    func unplugGoesStraightToIdle() async throws {
        try await withHarness { harness, accessory in
            harness.send(.arrived)
            #expect(await harness.recorder.wait(until: Self.reachedReady))
            let before = await harness.recorder.states.count

            await accessory.unplug()

            #expect(await harness.recorder.wait { $0.contains { if case .state(.idle) = $0 { true } else { false } } })
            let after = await harness.recorder.states.dropFirst(before)
            #expect(!after.contains { if case .waitingToRetry = $0 { true } else { false } },
                    "an unplugged receiver is not something to retry against: \(Array(after))")
        }
    }

    /// `LinkError.reset` had a diagnosis, a summary and a `FailureKind`, all of
    /// them unreachable: nothing ever threw it.
    @Test("An RST mid-session is diagnosed as a reset, not as a generic drop")
    func resetMidSessionIsDiagnosed() async throws {
        try await withHarness(timings: ReceiverSession.Timings(deviceDebounce: .milliseconds(50))) { harness, accessory in
            harness.send(.arrived)
            #expect(await harness.recorder.wait(until: Self.reachedReady))

            await accessory.resetLink()

            let diagnosed = await harness.recorder.wait(timeout: .seconds(20)) { events in
                events.contains {
                    if case .state(.waitingToRetry(.reset, _, _)) = $0 { true } else { false }
                }
            }
            let states = await harness.recorder.states
            #expect(diagnosed, "an RST should be diagnosed as a reset; states were \(states)")
        }
    }

    @Test("A recheck the receiver answers leaves the session alone")
    func recheckKeepsAHealthyLink() async throws {
        try await withHarness { harness, accessory in
            harness.send(.arrived)
            #expect(await harness.recorder.wait(until: Self.reachedReady))

            await harness.session.recheck()

            #expect(await harness.recorder.states.last == .ready)
            #expect(await accessory.stopSessionCount == 0)
        }
    }

    @Test("A recheck that gets no answer drops the link so it can be rebuilt")
    func recheckDropsADeadLink() async throws {
        try await withHarness(timings: ReceiverSession.Timings(deviceDebounce: .milliseconds(50))) { harness, accessory in
            harness.send(.arrived)
            #expect(await harness.recorder.wait(until: Self.reachedReady))
            await accessory.goQuiet()

            await harness.session.recheck()

            #expect(await harness.recorder.wait(timeout: .seconds(20)) { events in
                events.contains { if case .state(.waitingToRetry) = $0 { true } else { false } }
            }, "a link that does not answer after wake must be rebuilt, not kept")
        }
    }

    @Test("Quitting tells the receiver to stop the session, exactly once")
    func shutdownStopsSessionOnce() async throws {
        let accessory = FakeAccessory()
        let harness = await SessionHarness(
            makeLink: { IAP2Link(transport: accessory, initialSequence: 0x40, sleeper: Clock.linkSleeper) }
        )
        harness.send(.arrived)
        #expect(await harness.recorder.wait(until: Self.reachedReady))

        await harness.finish()

        #expect(await accessory.stopSessionCount == 1)
    }

    @Test("A write attempted while disconnected fails instead of hanging")
    func writeWhileDisconnected() async throws {
        try await withHarness { harness, _ in
            await harness.session.set(.noiseCancellation, to: 1)

            let result = try #require(await harness.recorder.writeResult(for: .noiseCancellation))
            #expect(throws: SessionError.notReady) { try result.get() }
        }
    }
}

/// The diagnosis that reaches the log and the popover. A bulk-write failure
/// used to be reported as an exclusive-access problem, which sends anyone
/// reading the log after entirely the wrong thing.
@Suite("Failure diagnosis")
struct FailureClassificationTests {
    @Test("Interface problems and mid-session problems are told apart")
    func transportErrors() {
        #expect(ReceiverSession.classify(USBTransport.TransportError.deviceNotFound) == .claimFailed)
        #expect(ReceiverSession.classify(USBTransport.TransportError.matchingFailed(-1)) == .claimFailed)
        #expect(ReceiverSession.classify(USBTransport.TransportError.claimFailed(-536_870_199)) == .claimFailed)
        #expect(ReceiverSession.classify(USBTransport.TransportError.writeFailed(-1)) == .transport)
        #expect(ReceiverSession.classify(USBTransport.TransportError.closed) == .transport)
    }

    @Test("Every link failure has a diagnosis of its own")
    func linkErrors() {
        #expect(ReceiverSession.classify(IAP2Link.LinkError.noSYN) == .noSYN)
        #expect(ReceiverSession.classify(IAP2Link.LinkError.noIdentification) == .noIdentification)
        #expect(ReceiverSession.classify(IAP2Link.LinkError.protocolNotOffered("x")) == .noIdentification)
        #expect(ReceiverSession.classify(IAP2Link.LinkError.noSessionStatus) == .sessionRefused)
        #expect(ReceiverSession.classify(IAP2Link.LinkError.externalAccessoryRefused(1)) == .sessionRefused)
        #expect(ReceiverSession.classify(IAP2Link.LinkError.reset) == .reset)
        #expect(ReceiverSession.classify(IAP2Link.LinkError.notAcknowledged(3)) == .transport)
    }

    @Test("Anything else is a transport problem rather than a wrong guess")
    func unknownErrors() {
        struct Odd: Error {}

        #expect(ReceiverSession.classify(Odd()) == .transport)
    }
}

/// A link that answers a request *before* it returns from `sendEA` — what the
/// receiver does when it replies faster than the link acknowledges the packet
/// that asked. Registering the pending request after the send returned dropped
/// that reply, and every poll timed out.
private actor EagerLink: AccessoryLink {
    nonisolated let eaInbound: AsyncStream<[UInt8]>
    private let continuation: AsyncStream<[UInt8]>.Continuation
    private var hasBeaten = false
    private(set) var end: LinkEnd?

    init() {
        (eaInbound, continuation) = AsyncStream.makeStream(of: [UInt8].self)
    }

    func open(protocolName: String, sessionID: UInt16, timeout: Duration) async throws -> DeviceIdentity {
        DeviceIdentity()
    }

    func sendEA(_ bytes: [UInt8]) async throws {
        guard let frame = CFDFrame(parsing: bytes), frame.message == CFDMessage.getMany.rawValue else { return }
        continuation.yield(Fixtures.getAllReply)
        // Long enough that the session has certainly dispatched it before this
        // send returns. Nothing else is in flight, so the trip is microseconds.
        try await Task.sleep(for: .milliseconds(50))
    }

    /// One device heartbeat, which is all the warm-up waits for. Beating back
    /// at every host beat would just ping-pong.
    func sendHeartbeatEA(_ bytes: [UInt8]) async throws {
        guard !hasBeaten else { return }
        hasBeaten = true
        continuation.yield(Fixtures.nodeHeartbeat)
    }

    func close() {
        end = end ?? .closed
        continuation.finish()
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
