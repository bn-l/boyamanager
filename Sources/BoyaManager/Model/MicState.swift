import Foundation
import OSLog
import UserNotifications

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

    private let preferences: Preferences
    private var session: ReceiverSession?
    private var eventTask: Task<Void, Never>?

    /// One low-battery notification per transmitter per online period.
    private var lowBatteryNotified: Set<Int> = []
    private var lastKnownOnline: [Int: Bool] = [:]
    private var lastPresenceNotice: [Int: Date] = [:]
    private var wasEverReady = false

    init(preferences: Preferences) {
        self.preferences = preferences
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

    func applyPollInterval() {
        guard let session else { return }
        let interval = preferences.pollInterval
        Task { await session.setPollInterval(interval) }
    }

    // MARK: - event handling

    /// The one place session events turn into UI state. Internal rather than
    /// private so `MicStateTests` can drive it without a device.
    func apply(_ event: SessionEvent) {
        switch event {
        case .state(let state):
            connection = state
            if state.isReady {
                wasEverReady = true
                lastError = nil
            }
            if case .failed(let kind) = state { lastError = kind.summary }
            if case .waitingToRetry(let kind, _, _) = state { lastError = kind.summary }
            if state == .idle || !state.isReady {
                notifyReceiverGoneIfNeeded(state: state)
            }
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
                logger.info("Write confirmed \(attr.name, privacy: .public) = \(value, privacy: .public)")
            case .failure(let error):
                lastError = Self.describe(error, attr: attr)
                logger.error("Write failed \(attr.name, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
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

    /// The transmitter the icon follows, honouring the preference. Nil when
    /// nothing is online.
    var iconTransmitter: TransmitterState? {
        let online = transmitters.filter(\.isOnline)
        switch preferences.iconSource {
        case .lowestOnline:
            return online.min { ($0.battery ?? 0) < ($1.battery ?? 0) }
        case .transmitter1:
            return online.first { $0.index == 1 }
        case .transmitter2:
            return online.first { $0.index == 2 }
        }
    }

    var iconKind: MicBadgeIcon.Kind {
        switch connection {
        case .ready:
            guard let transmitter = iconTransmitter else { return .offline }
            return .level(transmitter.battery ?? 0)
        case .connecting, .waitingToRetry:
            return .connecting
        case .idle, .failed:
            return .disconnected
        }
    }

    var isLowBattery: Bool {
        guard case .level(let level) = iconKind else { return false }
        return Int(level) <= preferences.lowBatteryThreshold
    }

    var statusLine: String {
        switch connection {
        case .ready:
            guard let lastUpdate else { return "Connected" }
            let seconds = max(0, Int(Date().timeIntervalSince(lastUpdate)))
            return "Connected · updated \(seconds)s ago"
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

    var tooltip: String {
        var parts = [iconKind.accessibilityDescription]
        if let battery = receiver.battery { parts.append("Receiver \(battery) of 4") }
        return parts.joined(separator: " · ")
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
                  let battery = transmitter.battery, Int(battery) <= preferences.lowBatteryThreshold,
                  !lowBatteryNotified.contains(index)
            else { continue }
            lowBatteryNotified.insert(index)
            notify(title: "Transmitter \(index) battery low", body: "\(battery) of 4 bars left.")
        }
    }

    private func notifyReceiverGoneIfNeeded(state: ConnectionState) {
        guard wasEverReady, preferences.notifyReceiverDisconnected else { return }
        guard case .failed(let reason) = state else { return }
        wasEverReady = false
        notify(title: "BOYA receiver disconnected", body: reason.summary.capitalizedFirst)
    }

    private func notify(title: String, body: String) {
        guard preferences.notificationsEnabled else { return }
        notificationLog.append(title)
        // UNUserNotificationCenter needs a real bundle; a bare `swift run`
        // executable has none and would trap rather than fail.
        guard Bundle.main.bundleIdentifier != nil else {
            logger.info("Notification skipped (unbundled): \(title, privacy: .public)")
            return
        }
        logger.notice("Notification: \(title, privacy: .public)")
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        let center = UNUserNotificationCenter.current()
        Task {
            do {
                _ = try await center.requestAuthorization(options: [.alert, .sound])
                try await center.add(request)
            } catch {
                logger.error("Notification failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

extension String {
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
