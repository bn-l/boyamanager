import Foundation
import OSLog
import ServiceManagement

private let logger = Logger(subsystem: BoyaLog.subsystem, category: "UI")

/// Everything the user can change about the app itself, backed by
/// `UserDefaults`. The store is injectable so `PreferencesTests` can round-trip
/// against a scratch suite instead of the real domain.
@MainActor
@Observable
final class Preferences {
    /// Which transmitter drives the menu bar icon.
    enum IconSource: String, CaseIterable, Sendable {
        case lowestOnline
        case transmitter1
        case transmitter2

        var title: String {
            switch self {
            case .lowestOnline: "Lowest of the connected transmitters"
            case .transmitter1: "Transmitter 1"
            case .transmitter2: "Transmitter 2"
            }
        }
    }

    private let defaults: UserDefaults
    private let loginItems: any LoginItemStore

    var pollSeconds: Int { didSet { store(pollSeconds, .pollSeconds) } }
    var lowBatteryThreshold: Int { didSet { store(lowBatteryThreshold, .lowBatteryThreshold) } }
    var iconSource: IconSource { didSet { store(iconSource.rawValue, .iconSource) } }
    var notificationsEnabled: Bool { didSet { store(notificationsEnabled, .notificationsEnabled) } }
    var notifyLowBattery: Bool { didSet { store(notifyLowBattery, .notifyLowBattery) } }
    var notifyTransmitterPresence: Bool { didSet { store(notifyTransmitterPresence, .notifyTransmitterPresence) } }
    var notifyReceiverDisconnected: Bool { didSet { store(notifyReceiverDisconnected, .notifyReceiverDisconnected) } }

    /// Mirrors the login-item registry, which is the real source of truth — the
    /// setting can be revoked in System Settings without the app being told.
    ///
    /// Three states, not two. `requiresApproval` means registration worked but
    /// the user has to confirm it in System Settings before it will ever run;
    /// collapsing that to "off" made the toggle snap back with no explanation
    /// and then fail on every attempt to switch it on again.
    private(set) var loginItem: LoginItemState

    var launchAtLogin: Bool {
        get { loginItem != .off }
        set { apply(launchAtLogin: newValue) }
    }

    static let pollChoices = [1, 2, 5]
    static let thresholdChoices = [1, 2]

    init(defaults: UserDefaults = .standard, loginItems: any LoginItemStore = AppLoginItem()) {
        self.defaults = defaults
        self.loginItems = loginItems
        pollSeconds = defaults.object(forKey: Key.pollSeconds.rawValue) as? Int ?? 2
        lowBatteryThreshold = defaults.object(forKey: Key.lowBatteryThreshold.rawValue) as? Int ?? 1
        iconSource = IconSource(rawValue: defaults.string(forKey: Key.iconSource.rawValue) ?? "") ?? .lowestOnline
        notificationsEnabled = defaults.object(forKey: Key.notificationsEnabled.rawValue) as? Bool ?? true
        notifyLowBattery = defaults.object(forKey: Key.notifyLowBattery.rawValue) as? Bool ?? true
        notifyTransmitterPresence = defaults.object(forKey: Key.notifyTransmitterPresence.rawValue) as? Bool ?? true
        notifyReceiverDisconnected = defaults.object(forKey: Key.notifyReceiverDisconnected.rawValue) as? Bool ?? true
        loginItem = loginItems.state
    }

    var pollInterval: Duration { .seconds(pollSeconds) }

    private enum Key: String {
        case pollSeconds
        case lowBatteryThreshold
        case iconSource
        case notificationsEnabled
        case notifyLowBattery
        case notifyTransmitterPresence
        case notifyReceiverDisconnected
    }

    private func store(_ value: Any, _ key: Key) {
        defaults.set(value, forKey: key.rawValue)
        logger.info("Preference \(key.rawValue, privacy: .public) = \(String(describing: value), privacy: .public)")
    }

    /// Re-reads the registry. The user can revoke a login item in System
    /// Settings while the app is running and nothing tells the app about it.
    func refreshLoginItem() {
        loginItem = loginItems.state
    }

    func openLoginItemsSettings() {
        loginItems.openSettings()
    }

    /// The registry, not the toggle, decides what the state ends up as: asking
    /// to register can land in `needsApproval`, and asking again once it has
    /// throws `kSMErrorAlreadyRegistered`. Either way the answer is whatever
    /// the registry says afterwards.
    private func apply(launchAtLogin enabled: Bool) {
        do {
            if enabled {
                try loginItems.register()
            } else {
                try loginItems.unregister()
            }
        } catch {
            logger.error("Launch at login change failed: \(error.localizedDescription, privacy: .public)")
        }
        loginItem = loginItems.state
        logger.notice("Launch at login is \(String(describing: self.loginItem), privacy: .public)")
    }
}

/// What the login-item registry says about this app.
enum LoginItemState: Sendable, Equatable {
    case off
    case on
    /// Registered, but the user has to approve it in System Settings before it
    /// will ever run. Also what a revoked consent looks like.
    case needsApproval
}

/// The seam `PreferencesTests` drives instead of the real registry —
/// `SMAppService` talks to a system daemon and cannot be exercised from a test.
@MainActor
protocol LoginItemStore {
    var state: LoginItemState { get }
    func register() throws
    func unregister() throws
    func openSettings()
}

struct AppLoginItem: LoginItemStore {
    var state: LoginItemState {
        // A bare `swift run` executable has no bundle, so there is nothing for
        // the registry to register.
        guard Bundle.main.bundleIdentifier != nil else { return .off }
        switch SMAppService.mainApp.status {
        case .enabled: return .on
        case .requiresApproval: return .needsApproval
        default: return .off
        }
    }

    func register() throws { try SMAppService.mainApp.register() }

    func unregister() throws { try SMAppService.mainApp.unregister() }

    func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}
