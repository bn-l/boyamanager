import AppKit
import Foundation
import OSLog
import UserNotifications

private let logger = Logger(subsystem: BoyaLog.subsystem, category: "UI")

/// What the system says about this app's notifications.
enum NotificationPermission: Sendable, Equatable {
    /// Never asked.
    case undetermined
    case allowed
    /// Refused, or switched off in System Settings. Nothing will be delivered
    /// until the user changes it there, so nothing should be handed over.
    case denied
}

/// The seam `MicStateTests` drives instead of `UNUserNotificationCenter`, which
/// needs a registered bundle and a real decision from the user.
@MainActor
protocol NotificationCentre {
    func permission() async -> NotificationPermission
    func requestPermission() async -> NotificationPermission
    func post(title: String, body: String) async
    func openSystemSettings()
}

struct SystemNotificationCentre: NotificationCentre {
    func permission() async -> NotificationPermission {
        guard isBundled else { return .denied }
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: return .allowed
        case .notDetermined: return .undetermined
        default: return .denied
        }
    }

    func requestPermission() async -> NotificationPermission {
        guard isBundled else { return .denied }
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            logger.notice("Notification authorization \(granted ? "granted" : "refused", privacy: .public)")
            return granted ? .allowed : .denied
        } catch {
            logger.error("Notification authorization failed: \(error.localizedDescription, privacy: .public)")
            return .denied
        }
    }

    func post(title: String, body: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
            logger.notice("Notification: \(title, privacy: .public)")
        } catch {
            logger.error("Notification failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    /// `UNUserNotificationCenter.current()` traps in a process with no bundle,
    /// which is what `swift run` and the icon renderers are.
    private var isBundled: Bool { Bundle.main.bundleIdentifier != nil }
}
