import AppKit
import OSLog
import SwiftUI

private let logger = Logger(subsystem: BoyaLog.subsystem, category: "SettingsWindow")

/// The one settings window, owned rather than left to the `Settings` scene.
///
/// Two things the scene could not do. It sits behind whatever you were working
/// in the moment it loses focus — and this window is opened from a menu bar
/// item, by someone who has something else in front of them by definition — so
/// it floats. And it sized itself, which left the tallest pane's content
/// running past the bottom edge of the window with the scrolling turned off.
@MainActor
final class SettingsWindowController {
    private let preferences: Preferences
    private let state: MicState
    private var window: NSWindow?

    init(preferences: Preferences, state: MicState) {
        self.preferences = preferences
        self.state = state
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate()
        logger.info("Settings window shown")
    }

    private func makeWindow() -> NSWindow {
        let controller = NSHostingController(rootView: SettingsView(preferences: preferences, state: state))
        // Each pane states the height it needs. This is what carries that
        // through to the window instead of the window deciding for itself.
        controller.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: controller)
        window.title = "BoyaManager Settings"
        // Not resizable: the panes are laid out at one width and scrolling is
        // off, so there is nothing for a drag to do but crop them.
        window.styleMask = [.titled, .closable]
        window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        // Closing hides it; the same window comes back on the next open.
        window.isReleasedWhenClosed = false
        window.center()
        logger.debug("Settings window created")
        return window
    }
}
