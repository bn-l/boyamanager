import Foundation
import Testing
@testable import BoyaManager

@Suite("Mic state")
@MainActor
struct MicStateTests {
    /// Async because the permission has to be read before anything can be
    /// posted — which is the whole point of the seam.
    private func makeState(
        notifications: Bool = true,
        centre: FakeNotificationCentre = FakeNotificationCentre(permission: .allowed)
    ) async -> MicState {
        let defaults = UserDefaults(suiteName: "boya-manager-tests-\(UUID().uuidString)")!
        let preferences = Preferences(defaults: defaults)
        preferences.notificationsEnabled = notifications
        let state = MicState(preferences: preferences, notifications: centre)
        await state.refreshNotificationPermission()
        return state
    }

    /// The captured `get_all`, with attributes overridden for the case at hand.
    private func snapshot(_ overrides: [Attr: UInt8] = [:]) -> AttributeSnapshot {
        var values = Fixtures.getAllExpected
        for (attr, value) in overrides { values[attr.rawValue] = [value] }
        return AttributeSnapshot(status: 0, values: values)
    }

    @Test("A real dump becomes the view state the popover shows")
    func snapshotBecomesViewState() async {
        let state = await makeState()

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
    func offlineTransmitterHidesBattery() async {
        let state = await makeState()

        state.apply(.state(.ready))
        state.apply(.snapshot(snapshot([.tx1Online: 0, .tx1Battery: 3])))

        #expect(state.transmitters[0].isOnline == false)
        #expect(state.transmitters[0].liveBattery == nil)
    }

    @Test("An attribute the device did not report is unavailable and its control is disabled")
    func absentAttributeIsUnavailable() async {
        let state = await makeState()

        state.apply(.state(.ready))
        state.apply(.snapshot(snapshot()))

        // Per-transmitter gain is a family attribute a mini 2 never sends.
        #expect(!state.isAvailable(.tx1Gain))
        #expect(!state.isEnabled(.tx1Gain))
        #expect(state.isEnabled(.noiseCancellation))
    }

    @Test("Nothing is enabled while the receiver is not ready")
    func nothingEnabledWhenNotReady() async {
        let state = await makeState()

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
        let state = await makeState()
        state.attach(to: session)
        let running = Task { await session.run() }
        deviceContinuation.yield(.arrived)
        #expect(await settle { state.connection.isReady && state.isAvailable(.noiseCancellation) })

        state.set(.noiseCancellation, to: 1)

        #expect(state.pendingWrites.contains(.noiseCancellation))
        #expect(!state.isEnabled(.noiseCancellation), "the control must be inert until the device confirms")
        #expect(await settle { state.value(.noiseCancellation) == 1 })
        #expect(state.pendingWrites.isEmpty)
        #expect(state.isEnabled(.noiseCancellation))

        // Awaited, not deferred into a detached task: a session torn down that
        // way outlives its test and keeps running alongside the next one.
        state.stop()
        await session.shutdown()
        deviceContinuation.finish()
        running.cancel()
        await running.value
    }

    @Test("The icon follows the lowest connected transmitter by default")
    func iconFollowsLowestOnline() async {
        let state = await makeState()
        state.apply(.state(.ready))

        state.apply(.snapshot(snapshot([.tx1Online: 1, .tx1Battery: 4, .tx2Online: 1, .tx2Battery: 2])))

        #expect(state.iconKind == .level(2))
    }

    @Test("An offline transmitter does not get a say, however low it was")
    func iconIgnoresOfflineTransmitters() async {
        let state = await makeState()
        state.apply(.state(.ready))

        state.apply(.snapshot(snapshot([.tx1Online: 0, .tx1Battery: 1, .tx2Online: 1, .tx2Battery: 3])))

        #expect(state.iconKind == .level(3))
    }

    @Test("Nothing online leaves the icon showing offline")
    func nothingOnlineShowsOffline() async {
        let state = await makeState()
        state.apply(.state(.ready))

        state.apply(.snapshot(snapshot([.tx1Online: 0, .tx2Online: 0])))

        #expect(state.iconKind == .offline)
    }

    @Test("Connection state drives the icon when there is nothing to report")
    func iconTracksConnection() async {
        let state = await makeState()

        state.apply(.state(.connecting(attempt: 1)))
        #expect(state.iconKind == .connecting)

        state.apply(.state(.waitingToRetry(reason: .transport, attempt: 2, seconds: 2)))
        #expect(state.iconKind == .connecting)

        state.apply(.state(.failed(.unresponsive)))
        #expect(state.iconKind == .disconnected)

        state.apply(.state(.idle))
        #expect(state.iconKind == .disconnected)
    }

    /// The threshold used to be a setting. It has no job now that the icon
    /// draws the last bar red: anything but one would put the warning and the
    /// drawing at odds.
    @Test("Low battery is exactly one bar left")
    func lowBatteryIsOneBar() async {
        let low = await makeState()
        low.apply(.state(.ready))
        low.apply(.snapshot(snapshot([.tx2Online: 1, .tx2Battery: 1])))
        #expect(low.isLowBattery)

        let fine = await makeState()
        fine.apply(.state(.ready))
        fine.apply(.snapshot(snapshot([.tx2Online: 1, .tx2Battery: 2])))
        #expect(!fine.isLowBattery)
    }

    @Test("The low-battery notification fires once per online period, not once per poll")
    func lowBatteryNotifiesOnce() async {
        let state = await makeState()
        state.apply(.state(.ready))
        // Establish the transmitter as online and healthy first.
        state.apply(.snapshot(snapshot([.tx2Online: 1, .tx2Battery: 3])))

        state.apply(.snapshot(snapshot([.tx2Online: 1, .tx2Battery: 1])))
        state.apply(.snapshot(snapshot([.tx2Online: 1, .tx2Battery: 1])))
        state.apply(.snapshot(snapshot([.tx2Online: 1, .tx2Battery: 0])))

        #expect(state.notificationLog.count { $0.contains("battery low") } == 1)
    }

    @Test("Going offline and back arms the low-battery notification again")
    func lowBatteryRearmsAfterOfflinePeriod() async {
        let state = await makeState()
        state.apply(.state(.ready))
        state.apply(.snapshot(snapshot([.tx2Online: 1, .tx2Battery: 3])))
        state.apply(.snapshot(snapshot([.tx2Online: 1, .tx2Battery: 1])))

        state.apply(.snapshot(snapshot([.tx2Online: 0, .tx2Battery: 1])))
        state.apply(.snapshot(snapshot([.tx2Online: 1, .tx2Battery: 1])))

        #expect(state.notificationLog.count { $0.contains("battery low") } == 2)
    }

    @Test("A transmitter connecting or disconnecting is announced once per transition")
    func presenceNotifications() async {
        let state = await makeState()
        state.apply(.state(.ready))
        state.apply(.snapshot(snapshot([.tx2Online: 0])))

        state.apply(.snapshot(snapshot([.tx2Online: 1, .tx2Battery: 4])))
        state.apply(.snapshot(snapshot([.tx2Online: 1, .tx2Battery: 4])))

        #expect(state.notificationLog.count { $0.contains("Transmitter 2 connected") } == 1)
    }

    @Test("The first snapshot is not announced as a transition — nothing changed yet")
    func firstSnapshotIsNotATransition() async {
        let state = await makeState()
        state.apply(.state(.ready))

        state.apply(.snapshot(snapshot([.tx2Online: 1, .tx2Battery: 4])))

        #expect(!state.notificationLog.contains { $0.contains("connected") })
    }

    /// Authorization was requested per notification and, on refusal, the error
    /// was logged and the content dropped — every time, forever. On this Mac
    /// the very first notification the app ever produced was lost that way.
    @Test("A refused permission stops the app handing anything to the centre")
    func deniedNotificationsAreNotPosted() async {
        let centre = FakeNotificationCentre(permission: .denied)
        let state = await makeState(centre: centre)
        state.apply(.state(.ready))
        state.apply(.snapshot(snapshot([.tx2Online: 0])))

        state.apply(.snapshot(snapshot([.tx2Online: 1, .tx2Battery: 4])))

        #expect(state.notificationPermission == .denied)
        #expect(centre.posted.isEmpty, "a refusal stands until the user changes it in System Settings")
        #expect(state.notificationLog.isEmpty)
    }

    @Test("An allowed centre is handed the notification")
    func allowedNotificationsArePosted() async {
        let centre = FakeNotificationCentre(permission: .allowed)
        let state = await makeState(centre: centre)
        state.apply(.state(.ready))
        state.apply(.snapshot(snapshot([.tx2Online: 0])))

        state.apply(.snapshot(snapshot([.tx2Online: 1, .tx2Battery: 4])))

        #expect(await settle { centre.posted.count { $0.contains("Transmitter 2 connected") } == 1 })
    }

    @Test("Authorization is asked for when notifications are switched on, and only once")
    func permissionIsRequestedOnce() async {
        let centre = FakeNotificationCentre(permission: .undetermined)
        let state = await makeState(centre: centre)

        await state.enableNotifications()
        await state.enableNotifications()

        #expect(centre.requestCount == 1, "the system only answers once; asking again does nothing")
        #expect(state.notificationPermission == .allowed)
    }

    @Test("Permission revoked in System Settings is picked up on the next look")
    func revokedPermissionIsNoticed() async {
        let centre = FakeNotificationCentre(permission: .allowed)
        let state = await makeState(centre: centre)
        #expect(state.notificationPermission == .allowed)

        centre.current = .denied
        await state.refreshNotificationPermission()

        #expect(state.notificationPermission == .denied)
    }

    @Test("Notifications are silent when switched off")
    func notificationsCanBeDisabled() async {
        let state = await makeState(notifications: false)
        state.apply(.state(.ready))
        state.apply(.snapshot(snapshot([.tx2Online: 1, .tx2Battery: 3])))

        state.apply(.snapshot(snapshot([.tx2Online: 1, .tx2Battery: 0])))

        #expect(state.notificationLog.isEmpty)
    }

    @Test("The receiver disconnecting is announced only after it had been connected")
    func receiverDisconnectNotification() async {
        let fresh = await makeState()
        fresh.apply(.state(.failed(.claimFailed)))
        #expect(fresh.notificationLog.isEmpty, "a receiver that was never there did not disconnect")

        let connected = await makeState()
        connected.apply(.state(.ready))
        connected.apply(.state(.failed(.unresponsive)))
        #expect(connected.notificationLog.count { $0.contains("receiver disconnected") } == 1)
    }

    /// `lastError` used to be written and never read: a timed-out or refused
    /// write re-enabled the control at the old value and said nothing at all.
    @Test("A failed write is shown under the controls, and cleared by the next good poll")
    func writeFailureIsVisible() async {
        let state = await makeState()
        state.apply(.state(.ready))

        state.apply(.writeResult(.rxGain, .failure(.outOfRange(9, 1...6))))

        #expect(state.writeError?.contains("Output Gain") == true)
        #expect(state.pendingWrites.isEmpty)

        state.apply(.snapshot(snapshot()))
        #expect(state.writeError == nil, "a good poll means the receiver is answering again")
    }

    @Test("A connection problem is not repeated under the controls — the status line says it")
    func connectionProblemIsNotAWriteError() async {
        let state = await makeState()
        state.apply(.state(.ready))

        state.apply(.state(.failed(.unresponsive)))

        #expect(state.lastError != nil)
        #expect(state.writeError == nil)
    }

    /// The popover kept showing the receiver's battery, firmware and a green
    /// "online" transmitter with bars while the footer said "No receiver
    /// connected".
    @Test("Losing the receiver clears everything that looked live")
    func losingTheReceiverClearsLiveData() async {
        let state = await makeState()
        state.apply(.state(.ready))
        state.apply(.identified(DeviceIdentity()))
        state.apply(.snapshot(snapshot([.tx2Online: 1, .tx2Battery: 3])))

        state.apply(.state(.idle))

        #expect(state.transmitters.allSatisfy { !$0.isOnline })
        #expect(state.transmitters.allSatisfy { $0.liveBattery == nil })
        #expect(state.receiver.battery == nil)
        #expect(state.identity == nil)
        #expect(state.lastUpdate == nil)
        #expect(!state.isAvailable(.noiseCancellation))
    }

    /// The disconnect notification only fired on `.failed`, so the most common
    /// disconnection of all — an unplug, which goes straight to idle — was
    /// never announced.
    @Test("The receiver going away is announced exactly once, whatever route it takes")
    func disconnectAnnouncedOnce() async {
        let unplugged = await makeState()
        unplugged.apply(.state(.ready))
        unplugged.apply(.state(.idle))
        #expect(unplugged.notificationLog.count { $0.contains("receiver disconnected") } == 1)

        let viaRetry = await makeState()
        viaRetry.apply(.state(.ready))
        viaRetry.apply(.state(.waitingToRetry(reason: .transport, attempt: 1, seconds: 1)))
        viaRetry.apply(.state(.idle))
        #expect(viaRetry.notificationLog.count { $0.contains("receiver disconnected") } == 1,
                "a retry followed by giving up is one disconnection, not two")
    }

    @Test("The status line says what is happening in each state")
    func statusLine() async {
        let state = await makeState()

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
    func tooltip() async {
        let state = await makeState()
        state.apply(.state(.ready))

        state.apply(.snapshot(snapshot([.tx2Online: 1, .tx2Battery: 3])))

        #expect(state.tooltip.contains("battery 3 of 4"))
        // The receiver is bus-powered; `rx_battery` reads a permanent 4 and is
        // not something to tell anyone about.
        #expect(!state.tooltip.contains("Receiver"))
    }
}

/// The notification centre, without a bundle or a user behind it.
@MainActor
final class FakeNotificationCentre: NotificationCentre {
    /// What the system currently says. Settable so a test can revoke consent
    /// the way System Settings does, behind the app's back.
    var current: NotificationPermission
    /// What `requestPermission()` produces.
    var answersRequestWith: NotificationPermission
    private(set) var requestCount = 0
    private(set) var posted: [String] = []
    private(set) var openedSettings = 0

    init(permission: NotificationPermission, answersRequestWith: NotificationPermission = .allowed) {
        current = permission
        self.answersRequestWith = answersRequestWith
    }

    func permission() async -> NotificationPermission { current }

    func requestPermission() async -> NotificationPermission {
        requestCount += 1
        current = answersRequestWith
        return current
    }

    func post(title: String, body: String) async { posted.append(title) }

    func openSystemSettings() { openedSettings += 1 }
}
