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

    var pollSeconds: Int { didSet { store(pollSeconds, .pollSeconds) } }
    var lowBatteryThreshold: Int { didSet { store(lowBatteryThreshold, .lowBatteryThreshold) } }
    var iconSource: IconSource { didSet { store(iconSource.rawValue, .iconSource) } }
    var notificationsEnabled: Bool { didSet { store(notificationsEnabled, .notificationsEnabled) } }
    var notifyLowBattery: Bool { didSet { store(notifyLowBattery, .notifyLowBattery) } }
    var notifyTransmitterPresence: Bool { didSet { store(notifyTransmitterPresence, .notifyTransmitterPresence) } }
    var notifyReceiverDisconnected: Bool { didSet { store(notifyReceiverDisconnected, .notifyReceiverDisconnected) } }

    /// Mirrors `SMAppService`, which is the real source of truth — the setting
    /// can be revoked in System Settings without the app being told.
    var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != Self.isRegisteredForLogin else { return }
            apply(launchAtLogin: launchAtLogin)
        }
    }

    static let pollChoices = [1, 2, 5]
    static let thresholdChoices = [1, 2]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        pollSeconds = defaults.object(forKey: Key.pollSeconds.rawValue) as? Int ?? 2
        lowBatteryThreshold = defaults.object(forKey: Key.lowBatteryThreshold.rawValue) as? Int ?? 1
        iconSource = IconSource(rawValue: defaults.string(forKey: Key.iconSource.rawValue) ?? "") ?? .lowestOnline
        notificationsEnabled = defaults.object(forKey: Key.notificationsEnabled.rawValue) as? Bool ?? true
        notifyLowBattery = defaults.object(forKey: Key.notifyLowBattery.rawValue) as? Bool ?? true
        notifyTransmitterPresence = defaults.object(forKey: Key.notifyTransmitterPresence.rawValue) as? Bool ?? true
        notifyReceiverDisconnected = defaults.object(forKey: Key.notifyReceiverDisconnected.rawValue) as? Bool ?? true
        launchAtLogin = Self.isRegisteredForLogin
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

    private static var isRegisteredForLogin: Bool {
        guard Bundle.main.bundleIdentifier != nil else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    private func apply(launchAtLogin enabled: Bool) {
        guard Bundle.main.bundleIdentifier != nil else {
            logger.error("Launch at login needs the bundled app, not a bare executable")
            return
        }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            logger.notice("Launch at login \(enabled ? "enabled" : "disabled", privacy: .public)")
        } catch {
            logger.error("Launch at login change failed: \(error.localizedDescription, privacy: .public)")
            launchAtLogin = Self.isRegisteredForLogin
        }
    }
}
