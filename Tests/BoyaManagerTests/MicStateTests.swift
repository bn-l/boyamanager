import Foundation
import Testing
@testable import BoyaManager

@Suite("Mic state")
@MainActor
struct MicStateTests {
    private func makeState(
        iconSource: Preferences.IconSource = .lowestOnline,
        lowBatteryThreshold: Int = 1,
        notifications: Bool = true
    ) -> MicState {
        let defaults = UserDefaults(suiteName: "boya-manager-tests-\(UUID().uuidString)")!
        let preferences = Preferences(defaults: defaults)
        preferences.iconSource = iconSource
        preferences.lowBatteryThreshold = lowBatteryThreshold
        preferences.notificationsEnabled = notifications
        return MicState(preferences: preferences)
    }

    /// The captured `get_all`, with attributes overridden for the case at hand.
    private func snapshot(_ overrides: [Attr: UInt8] = [:]) -> AttributeSnapshot {
        var values = Fixtures.getAllExpected
        for (attr, value) in overrides { values[attr.rawValue] = [value] }
        return AttributeSnapshot(status: 0, values: values)
    }

    @Test("A real dump becomes the view state the popover shows")
    func snapshotBecomesViewState() {
        let state = makeState()

        state.apply(.state(.ready))
        state.apply(.snapshot(snapshot()))

        #expect(state.transmitters.count == 2)
        #expect(state.transmitters[1].isOnline)
        #expect(state.transmitters[1].battery == 3)
        #expect(state.receiver.battery == 4)
        #expect(state.value(.rxGain) == 4)
        #expect(state.lastUpdate != nil)
    }

    @Test("An offline transmitter shows no live battery even though the device kept the stale value")
    func offlineTransmitterHidesBattery() {
        let state = makeState()

        state.apply(.state(.ready))
        state.apply(.snapshot(snapshot([.tx1Online: 0, .tx1Battery: 3])))

        #expect(state.transmitters[0].isOnline == false)
        #expect(state.transmitters[0].liveBattery == nil)
    }

    @Test("An attribute the device did not report is unavailable and its control is disabled")
    func absentAttributeIsUnavailable() {
        let state = makeState()

        state.apply(.state(.ready))
        state.apply(.snapshot(snapshot()))

        // Per-transmitter gain is a family attribute a mini 2 never sends.
        #expect(!state.isAvailable(.tx1Gain))
        #expect(!state.isEnabled(.tx1Gain))
        #expect(state.isEnabled(.noiseCancellation))
    }

    @Test("Nothing is enabled while the receiver is not ready")
    func nothingEnabledWhenNotReady() {
        let state = makeState()

        state.apply(.snapshot(snapshot()))

        #expect(!state.isAvailable(.noiseCancellation))
        #expect(state.iconKind == .disconnected)
    }

    /// Runs `check` every 10 ms until it holds or the deadline passes.
    private func settle(within timeout: Duration = .seconds(10), until check: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if check() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return check()
    }

    @Test("A control is disabled while its write is in flight, so it cannot flicker")
    func pendingWriteDisablesControl() async throws {
        // End to end against a scripted receiver: the flicker this guards
        // against only exists because a real write takes a round trip.
        let accessory = FakeAccessory()
        let (deviceEvents, deviceContinuation) = AsyncStream.makeStream(of: DeviceEvent.self)
        let session = ReceiverSession(
            makeLink: { IAP2Link(transport: accessory, initialSequence: 0x40) },
            deviceEvents: deviceEvents,
            sleeper: Clock().sleeper()
        )
        let state = makeState()
        state.attach(to: session)
        let running = Task { await session.run() }
        defer {
            deviceContinuation.finish()
            running.cancel()
            Task { await session.shutdown() }
        }
        deviceContinuation.yield(.arrived)
        #expect(await settle { state.connection.isReady && state.isAvailable(.noiseCancellation) })

        state.set(.noiseCancellation, to: 1)

        #expect(state.pendingWrites.contains(.noiseCancellation))
        #expect(!state.isEnabled(.noiseCancellation), "the control must be inert until the device confirms")
        #expect(await settle { state.value(.noiseCancellation) == 1 })
        #expect(state.pendingWrites.isEmpty)
        #expect(state.isEnabled(.noiseCancellation))
    }

    @Test("The icon follows the lowest connected transmitter by default")
    func iconFollowsLowestOnline() {
        let state = makeState(iconSource: .lowestOnline, lowBatteryThreshold: 0)
        state.apply(.state(.ready))

        state.apply(.snapshot(snapshot([.tx1Online: 1, .tx1Battery: 4, .tx2Online: 1, .tx2Battery: 2])))

        #expect(state.iconKind == .level(2))
    }

    @Test("The icon can be pinned to one transmitter")
    func iconFollowsChosenTransmitter() {
        let state = makeState(iconSource: .transmitter1, lowBatteryThreshold: 0)
        state.apply(.state(.ready))

        state.apply(.snapshot(snapshot([.tx1Online: 1, .tx1Battery: 4, .tx2Online: 1, .tx2Battery: 2])))

        #expect(state.iconKind == .level(4))
    }

    @Test("A pinned transmitter that is offline leaves the icon showing offline, not the other one")
    func pinnedOfflineShowsOffline() {
        let state = makeState(iconSource: .transmitter1)
        state.apply(.state(.ready))

        state.apply(.snapshot(snapshot([.tx1Online: 0, .tx2Online: 1, .tx2Battery: 3])))

        #expect(state.iconKind == .offline)
    }

    @Test("Connection state drives the icon when there is nothing to report")
    func iconTracksConnection() {
        let state = makeState()

        state.apply(.state(.connecting(attempt: 1)))
        #expect(state.iconKind == .connecting)

        state.apply(.state(.waitingToRetry(reason: .transport, attempt: 2, seconds: 2)))
        #expect(state.iconKind == .connecting)

        state.apply(.state(.failed(.unresponsive)))
        #expect(state.iconKind == .disconnected)

        state.apply(.state(.idle))
        #expect(state.iconKind == .disconnected)
    }

    @Test("Low battery is decided by the threshold, not by a fixed level")
    func lowBatteryThreshold() {
        let low = makeState(lowBatteryThreshold: 2)
        low.apply(.state(.ready))
        low.apply(.snapshot(snapshot([.tx2Online: 1, .tx2Battery: 2])))
        #expect(low.isLowBattery)

        let fine = makeState(lowBatteryThreshold: 1)
        fine.apply(.state(.ready))
        fine.apply(.snapshot(snapshot([.tx2Online: 1, .tx2Battery: 2])))
        #expect(!fine.isLowBattery)
    }

    @Test("The low-battery notification fires once per online period, not once per poll")
    func lowBatteryNotifiesOnce() {
        let state = makeState(lowBatteryThreshold: 1)
        state.apply(.state(.ready))
        // Establish the transmitter as online and healthy first.
        state.apply(.snapshot(snapshot([.tx2Online: 1, .tx2Battery: 3])))

        state.apply(.snapshot(snapshot([.tx2Online: 1, .tx2Battery: 1])))
        state.apply(.snapshot(snapshot([.tx2Online: 1, .tx2Battery: 1])))
        state.apply(.snapshot(snapshot([.tx2Online: 1, .tx2Battery: 0])))

        #expect(state.notificationLog.count { $0.contains("battery low") } == 1)
    }

    @Test("Going offline and back arms the low-battery notification again")
    func lowBatteryRearmsAfterOfflinePeriod() {
        let state = makeState(lowBatteryThreshold: 1)
        state.apply(.state(.ready))
        state.apply(.snapshot(snapshot([.tx2Online: 1, .tx2Battery: 3])))
        state.apply(.snapshot(snapshot([.tx2Online: 1, .tx2Battery: 1])))

        state.apply(.snapshot(snapshot([.tx2Online: 0, .tx2Battery: 1])))
        state.apply(.snapshot(snapshot([.tx2Online: 1, .tx2Battery: 1])))

        #expect(state.notificationLog.count { $0.contains("battery low") } == 2)
    }

    @Test("A transmitter connecting or disconnecting is announced once per transition")
    func presenceNotifications() {
        let state = makeState()
        state.apply(.state(.ready))
        state.apply(.snapshot(snapshot([.tx2Online: 0])))

        state.apply(.snapshot(snapshot([.tx2Online: 1, .tx2Battery: 4])))
        state.apply(.snapshot(snapshot([.tx2Online: 1, .tx2Battery: 4])))

        #expect(state.notificationLog.count { $0.contains("Transmitter 2 connected") } == 1)
    }

    @Test("The first snapshot is not announced as a transition — nothing changed yet")
    func firstSnapshotIsNotATransition() {
        let state = makeState()
        state.apply(.state(.ready))

        state.apply(.snapshot(snapshot([.tx2Online: 1, .tx2Battery: 4])))

        #expect(!state.notificationLog.contains { $0.contains("connected") })
    }

    @Test("Notifications are silent when switched off")
    func notificationsCanBeDisabled() {
        let state = makeState(lowBatteryThreshold: 1, notifications: false)
        state.apply(.state(.ready))
        state.apply(.snapshot(snapshot([.tx2Online: 1, .tx2Battery: 3])))

        state.apply(.snapshot(snapshot([.tx2Online: 1, .tx2Battery: 0])))

        #expect(state.notificationLog.isEmpty)
    }

    @Test("The receiver disconnecting is announced only after it had been connected")
    func receiverDisconnectNotification() {
        let fresh = makeState()
        fresh.apply(.state(.failed(.claimFailed)))
        #expect(fresh.notificationLog.isEmpty, "a receiver that was never there did not disconnect")

        let connected = makeState()
        connected.apply(.state(.ready))
        connected.apply(.state(.failed(.unresponsive)))
        #expect(connected.notificationLog.count { $0.contains("receiver disconnected") } == 1)
    }

    @Test("A failed write is reported in words the popover can show")
    func writeFailureMessage() {
        let state = makeState()
        state.apply(.state(.ready))

        state.apply(.writeResult(.rxGain, .failure(.outOfRange(9, 1...6))))

        #expect(state.lastError?.contains("Output Gain") == true)
        #expect(state.pendingWrites.isEmpty)
    }

    @Test("The status line says what is happening in each state")
    func statusLine() {
        let state = makeState()

        state.apply(.state(.idle))
        #expect(state.statusLine == "No receiver connected")

        state.apply(.state(.connecting(attempt: 3)))
        #expect(state.statusLine.contains("attempt 3"))

        state.apply(.state(.failed(.unresponsive)))
        #expect(state.statusLine.hasPrefix("Failed:"))

        state.apply(.state(.ready))
        #expect(state.statusLine.hasPrefix("Connected"))
    }

    @Test("The tooltip names the battery level and the receiver")
    func tooltip() {
        let state = makeState(lowBatteryThreshold: 0)
        state.apply(.state(.ready))

        state.apply(.snapshot(snapshot([.tx2Online: 1, .tx2Battery: 3])))

        #expect(state.tooltip.contains("battery 3 of 4"))
        #expect(state.tooltip.contains("Receiver 4 of 4"))
    }
}
