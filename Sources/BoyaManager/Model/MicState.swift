import Foundation
import OSLog

private let logger = Logger(subsystem: BoyaLog.subsystem, category: "UI")

/// Everything the UI reads, fed by the session's event stream. Views never talk
/// to the session directly — writes go through `set(_:to:)` so the
/// disabled-while-pending rule holds everywhere.
@MainActor
@Observable
final class MicState {
    private(set) var connection: ConnectionState = .idle
    private(set) var identity: DeviceIdentity?
    private(set) var snapshot = AttributeSnapshot()
    private(set) var lastUpdate: Date?
    private(set) var pendingWrites: Set<Attr> = []
    private(set) var lastError: String?
    /// Titles of the notifications posted this run, newest last. Kept so the
    /// "once per online period" rules are visible in the log and testable.
    private(set) var notificationLog: [String] = []
    /// What the system allows, as of the last look. Settings shows a way out
    /// when it is `.denied`.
    private(set) var notificationPermission: NotificationPermission = .undetermined

    private let preferences: Preferences
    private let notifications: any NotificationCentre
    private var session: ReceiverSession?
    private var eventTask: Task<Void, Never>?

    /// One low-battery notification per transmitter per online period.
    private var lowBatteryNotified: Set<Int> = []
    private var lastKnownOnline: [Int: Bool] = [:]
    private var lastPresenceNotice: [Int: Date] = [:]
    private var wasEverReady = false
    private var errorExpiry: Task<Void, Never>?
    /// Long enough to read, short enough not to sit there after the fact.
    private static let errorLifetime = Duration.seconds(8)

    init(preferences: Preferences, notifications: any NotificationCentre = SystemNotificationCentre()) {
        self.preferences = preferences
        self.notifications = notifications
    }

    func attach(to session: ReceiverSession) {
        self.session = session
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            for await event in session.events {
                self?.apply(event)
            }
        }
    }

    func stop() {
        eventTask?.cancel()
        eventTask = nil
    }

    // MARK: - intent

    func set(_ attr: Attr, to value: UInt8) {
        guard let session, !pendingWrites.contains(attr) else { return }
        logger.notice("UI requests \(attr.name, privacy: .public) = \(value, privacy: .public)")
        pendingWrites.insert(attr)
        Task { await session.set(attr, to: value) }
    }

    func setRisky(_ attr: Attr, to value: UInt8) {
        guard let session, !pendingWrites.contains(attr) else { return }
        logger.notice("UI requests risky \(attr.name, privacy: .public) = \(value, privacy: .public)")
        pendingWrites.insert(attr)
        Task { await session.setRisky(attr, to: value) }
    }

    func retry() {
        guard let session else { return }
        Task { await session.retryNow() }
    }

    /// The popover being on screen is what makes fast polling worth its cost.
    func setPopoverVisible(_ visible: Bool) {
        guard let session else { return }
        Task { await session.setPopoverVisible(visible) }
    }

    // MARK: - event handling

    /// The one place session events turn into UI state. Internal rather than
    /// private so `MicStateTests` can drive it without a device.
    func apply(_ event: SessionEvent) {
        switch event {
        case .state(let state):
            let wasReady = connection.isReady
            connection = state
            if state.isReady {
                wasEverReady = true
                errorExpiry?.cancel()
                lastError = nil
            } else if wasReady {
                // Leaving ready: everything on screen came from a receiver we
                // are no longer talking to, and showing a stale battery as
                // live is worse than showing nothing.
                clearLiveData()
                notifyReceiverGone(state: state)
            }
            if case .failed(let kind) = state { lastError = kind.summary }
            if case .waitingToRetry(let kind, _, _) = state { lastError = kind.summary }
        case .identified(let identity):
            self.identity = identity
        case .snapshot(let snapshot):
            self.snapshot = snapshot
            lastUpdate = Date()
            checkTransmitterNotifications()
        case .writeResult(let attr, let result):
            pendingWrites.remove(attr)
            switch result {
            case .success(let value):
                errorExpiry?.cancel()
                lastError = nil
                logger.info("Write confirmed \(attr.name, privacy: .public) = \(value, privacy: .public)")
            case .failure(let error):
                show(error: Self.describe(error, attr: attr))
                logger.error("Write failed \(attr.name, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// A write error outlives the next poll. Clearing it on any snapshot gave
    /// it a life of one poll interval — as little as a second — which is not
    /// long enough to read a sentence that explains why nothing happened.
    private func show(error message: String) {
        lastError = message
        errorExpiry?.cancel()
        errorExpiry = Task { [weak self] in
            try? await Task.sleep(for: Self.errorLifetime)
            guard !Task.isCancelled else { return }
            self?.lastError = nil
        }
    }

    /// Nothing the receiver told us survives losing it.
    private func clearLiveData() {
        snapshot = AttributeSnapshot()
        identity = nil
        lastUpdate = nil
        lastKnownOnline = [:]
        lowBatteryNotified = []
        pendingWrites = []
    }

    private static func describe(_ error: SessionError, attr: Attr) -> String {
        switch error {
        case .notReady: "\(attr.title) could not be changed — the receiver is not connected."
        case .timeout: "\(attr.title) did not answer."
        case .unavailable: "\(attr.title) is not available right now."
        case .outOfRange(let value, let range): "\(value) is outside \(range.lowerBound)…\(range.upperBound) for \(attr.title)."
        case .riskyWriteRefused: "\(attr.title) needs to be changed from Settings › Advanced."
        }
    }

    // MARK: - derived state

    var transmitters: [TransmitterState] { [snapshot.tx1, snapshot.tx2] }

    var receiver: ReceiverState { snapshot.receiver }

    /// The transmitter the icon follows: whichever online one has least left.
    /// Nil when nothing is online.
    var iconTransmitter: TransmitterState? {
        transmitters.filter(\.isOnline).min { ($0.battery ?? 0) < ($1.battery ?? 0) }
    }

    var iconKind: MicBadgeIcon.Kind {
        switch connection {
        case .ready:
            guard let transmitter = iconTransmitter else { return .offline }
            return .level(transmitter.battery ?? 0, online: transmitters.count(where: \.isOnline))
        case .connecting, .waitingToRetry:
            return .connecting
        case .idle, .failed:
            return .disconnected
        }
    }

    /// One bar left, the level at which the icon draws the bar red. Taken from
    /// the icon rather than configured, so the warning and the drawing cannot
    /// disagree.
    var isLowBattery: Bool {
        guard let level = iconKind.level else { return false }
        return level <= MicBadgeIcon.lowBatteryLevel
    }

    /// Deliberately without the "updated Ns ago" part: a string formatted once
    /// sat at "0s ago" until the next poll redrew it. The popover renders that
    /// with `Text(_:style:.relative)`, which keeps counting on its own.
    var statusLine: String {
        switch connection {
        case .ready:
            return "Connected"
        case .connecting(let attempt):
            return attempt > 1 ? "Connecting… (attempt \(attempt))" : "Connecting…"
        case .waitingToRetry(let reason, let attempt, let seconds):
            return "\(reason.summary.capitalizedFirst) — retrying in \(seconds)s (attempt \(attempt))"
        case .failed(let reason):
            return "Failed: \(reason.summary)"
        case .idle:
            return "No receiver connected"
        }
    }

    /// No receiver battery: the mini 2 receiver is bus-powered and `rx_battery`
    /// reads a permanent 4.
    var tooltip: String {
        iconKind.accessibilityDescription
    }

    /// A control is only usable when the device reported the attribute and no
    /// write is in flight for it.
    func isAvailable(_ attr: Attr) -> Bool {
        connection.isReady && snapshot[attr] != nil
    }

    func isEnabled(_ attr: Attr) -> Bool {
        isAvailable(attr) && !pendingWrites.contains(attr)
    }

    func value(_ attr: Attr) -> UInt8? { snapshot.byte(attr) }

    /// A failed write, in words the popover shows under the controls. Only
    /// while connected: a connection problem is already spelled out by
    /// `statusLine` and does not need saying twice.
    var writeError: String? {
        connection.isReady ? lastError : nil
    }

    // MARK: - notifications

    private func checkTransmitterNotifications() {
        for transmitter in transmitters {
            let index = transmitter.index
            let wasOnline = lastKnownOnline[index]
            lastKnownOnline[index] = transmitter.isOnline

            if let wasOnline, wasOnline != transmitter.isOnline {
                if !transmitter.isOnline { lowBatteryNotified.remove(index) }
                let now = Date()
                let recent = lastPresenceNotice[index].map { now.timeIntervalSince($0) < 5 } ?? false
                if preferences.notifyTransmitterPresence, !recent {
                    lastPresenceNotice[index] = now
                    notify(
                        title: "Transmitter \(index) \(transmitter.isOnline ? "connected" : "disconnected")",
                        body: transmitter.isOnline ? "BOYA mini 2" : "It is no longer reaching the receiver."
                    )
                }
            }

            guard transmitter.isOnline, preferences.notifyLowBattery,
                  let battery = transmitter.battery, battery <= MicBadgeIcon.lowBatteryLevel,
                  !lowBatteryNotified.contains(index)
            else { continue }
            lowBatteryNotified.insert(index)
            notify(title: "Transmitter \(index) battery low", body: "\(battery) of 4 bars left.")
        }
    }

    /// Announced on the transition out of ready, whatever the receiver went to.
    /// Waiting for `.failed` meant the common case — an unplug, which goes
    /// straight to idle — was never announced at all, and the give-up after a
    /// later replug was announced with the wrong reason.
    private func notifyReceiverGone(state: ConnectionState) {
        guard wasEverReady, preferences.notifyReceiverDisconnected else { return }
        wasEverReady = false
        let reason: String
        switch state {
        case .failed(let kind), .waitingToRetry(let kind, _, _): reason = kind.summary.capitalizedFirst
        default: reason = "It is no longer connected."
        }
        notify(title: "BOYA receiver disconnected", body: reason)
    }

    private func notify(title: String, body: String) {
        guard preferences.notificationsEnabled else { return }
        guard notificationPermission == .allowed else {
            logger.info("Notification not shown (\(String(describing: self.notificationPermission), privacy: .public)): \(title, privacy: .public)")
            return
        }
        notificationLog.append(title)
        Task { await notifications.post(title: title, body: body) }
    }

    // MARK: - notification permission

    /// Reads what the system currently allows. Asking per notification, which
    /// is what this used to do, meant a refusal was rediscovered and logged on
    /// every single event and the content thrown away each time.
    func refreshNotificationPermission() async {
        notificationPermission = await notifications.permission()
    }

    /// Asks, once, when the user switches notifications on — which is a moment
    /// they are expecting to be asked. Asking on the first event instead put
    /// the prompt at an arbitrary point, and a prompt that is missed leaves
    /// every notification after it silently dropped.
    func enableNotifications() async {
        notificationPermission = notificationPermission == .undetermined
            ? await notifications.requestPermission()
            : await notifications.permission()
    }

    func openNotificationSettings() {
        notifications.openSystemSettings()
    }
}

extension String {
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
