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

    /// The phase of the connecting fade, 0…1, which is all the icon needs to
    /// draw it. It sits at 1 in every other state.
    private(set) var iconPulse: Double = 1

    private let preferences: Preferences
    private let notifications: any NotificationCentre
    private let sleeper: @Sendable (Duration) async throws -> Void
    private var session: ReceiverSession?
    private var eventTask: Task<Void, Never>?
    private var pulseTask: Task<Void, Never>?

    /// One fade out and back. Slow enough to read as breathing rather than as
    /// blinking, and stepped finely enough that neither end looks like a jump.
    private static let pulsePeriod = Duration.milliseconds(1_600)
    private static let pulseTick = Duration.milliseconds(80)

    /// One low-battery notification per transmitter per online period.
    private var lowBatteryNotified: Set<Int> = []
    private var lastKnownOnline: [Int: Bool] = [:]
    private var lastPresenceNotice: [Int: Date] = [:]
    private var wasEverReady = false
    private var errorExpiry: Task<Void, Never>?
    /// Long enough to read, short enough not to sit there after the fact.
    private static let errorLifetime = Duration.seconds(8)

    /// `sleeper` is injected so the fade can be driven on a compressed clock in
    /// tests, the way `ReceiverSession` takes its delays.
    init(
        preferences: Preferences,
        notifications: any NotificationCentre = SystemNotificationCentre(),
        sleeper: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.preferences = preferences
        self.notifications = notifications
        self.sleeper = sleeper
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
        pulseTask?.cancel()
        pulseTask = nil
    }

    /// `MenuBarExtra` does not vend its `NSStatusItem`, so there is no layer to
    /// hang a `CABasicAnimation` on, and a SwiftUI animation inside the label
    /// does not run because the label is rendered to an image. Stepping the
    /// phase and letting Observation redraw the label is what is left.
    private func updatePulse() {
        guard iconKind == .connecting else {
            pulseTask?.cancel()
            pulseTask = nil
            iconPulse = 1
            return
        }
        guard pulseTask == nil else { return }
        pulseTask = Task { [weak self] in
            var elapsed = Duration.zero
            while !Task.isCancelled {
                guard let self else { return }
                iconPulse = Self.pulsePhase(at: elapsed)
                guard (try? await sleeper(Self.pulseTick)) != nil else { return }
                elapsed += Self.pulseTick
            }
        }
    }

    /// A cosine, so the turn at each end of the fade is gentle rather than a
    /// corner. The injected sleeper may run faster than real time and this
    /// takes its phase from the nominal tick, so the fade keeps its shape.
    private static func pulsePhase(at elapsed: Duration) -> Double {
        let turns = Double(elapsed.milliseconds) / Double(pulsePeriod.milliseconds)
        return (1 - cos(2 * .pi * turns)) / 2
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
            updatePulse()
        case .identified(let identity):
            self.identity = identity
        case .snapshot(let snapshot):
            self.snapshot = snapshot
            lastUpdate = Date()
            checkTransmitterNotifications()
        case let .writeResult(attr, result):
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
        case let .outOfRange(value, range): "\(value) is outside \(range.lowerBound)…\(range.upperBound) for \(attr.title)."
        case .riskyWriteRefused: "\(attr.title) needs to be changed from Settings › Advanced."
        case let .notApplied(requested, actual):
            "\(attr.title) did not take \(attr.describe([requested])) — the receiver still reads \(attr.describe([actual]))."
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
        case let .waitingToRetry(reason, attempt, seconds):
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

    /// Why the receiver is not connected, for the popover. Nil while it is
    /// connected, connecting, or simply absent: the status pill says all three
    /// on its own, and the one thing it has no room for is a reason.
    var connectionProblem: String? {
        switch connection {
        case let .failed(kind): kind.summary.capitalizedFirst
        case let .waitingToRetry(kind, attempt, _): "\(kind.summary.capitalizedFirst) — attempt \(attempt)"
        case .ready, .connecting, .idle: nil
        }
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
        case let .failed(kind), let .waitingToRetry(kind, _, _): reason = kind.summary.capitalizedFirst
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
        record(await notifications.permission())
    }

    /// Startup. Notifications are on by default, so on a machine that has never
    /// heard of this app nothing would ever ask: the Settings toggle is the only
    /// caller of `enableNotifications()` and a preference that starts on never
    /// changes. Permission stayed undetermined and every notification was
    /// dropped — the same silence the prompt exists to prevent.
    func prepareNotifications() async {
        await refreshNotificationPermission()
        guard preferences.notificationsEnabled, notificationPermission == .undetermined else { return }
        logger.notice("Notifications are on and unauthorized — asking")
        record(await notifications.requestPermission())
    }

    /// Asks, once, when the user switches notifications on — which is a moment
    /// they are expecting to be asked. Asking on the first event instead put
    /// the prompt at an arbitrary point, and a prompt that is missed leaves
    /// every notification after it silently dropped.
    func enableNotifications() async {
        record(notificationPermission == .undetermined
            ? await notifications.requestPermission()
            : await notifications.permission())
    }

    /// A low battery is a level, not an edge: the warning is armed once per
    /// online period, and arming it while nothing could be posted spent the
    /// only warning on a notification the user never saw. Permission arriving
    /// afterwards re-arms it, so the next poll says what the last one could not.
    private func record(_ permission: NotificationPermission) {
        let wasBlocked = notificationPermission != .allowed
        notificationPermission = permission
        guard permission == .allowed, wasBlocked else { return }
        lowBatteryNotified = []
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
