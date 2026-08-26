import AppKit
import OSLog
import SwiftUI

private let logger = Logger(subsystem: BoyaLog.subsystem, category: "App")

@main
@MainActor
enum BoyaManagerMain {
    static func main() {
        let arguments = CommandLine.arguments

        if let flag = arguments.firstIndex(of: "--render-icons"), arguments.indices.contains(flag + 1) {
            MicBadgeIcon.writePreviews(to: URL(filePath: arguments[flag + 1], directoryHint: .isDirectory))
            return
        }
        if let flag = arguments.firstIndex(of: "--render-ui"), arguments.indices.contains(flag + 1) {
            UIPreview.write(to: URL(filePath: arguments[flag + 1], directoryHint: .isDirectory))
            return
        }
        if arguments.contains("--dump-log") {
            print(BoyaLog.streamCommand)
            return
        }
        if arguments.contains("--probe") {
            var attribute: UInt8?
            if let flag = arguments.firstIndex(of: "--get"), arguments.indices.contains(flag + 1) {
                attribute = Probe.attribute(named: arguments[flag + 1])
                guard attribute != nil else {
                    print("unknown attribute \(arguments[flag + 1])")
                    return
                }
            }
            Probe.run(reading: attribute)
            return
        }

        BoyaManagerApp.main()
    }
}

struct BoyaManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self)
    private var delegate
    @Environment(\.openSettings)
    private var openSettings

    var body: some Scene {
        MenuBarExtra {
            PopoverView(state: Shared.controller.state) {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
        } label: {
            Image(nsImage: Shared.controller.menuBarImage)
                .accessibilityLabel(Shared.controller.state.tooltip)
                .help(Shared.controller.state.tooltip)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(preferences: Shared.controller.preferences, state: Shared.controller.state)
        }
    }
}

/// The app's one long-lived object graph. A menu bar app has exactly one of
/// each of these and the `App` struct is re-created freely, so they live here
/// rather than in `@State`.
@MainActor
enum Shared {
    static let controller = AppController()
}

@MainActor
@Observable
final class AppController {
    let preferences: Preferences
    let state: MicState

    private let watcher = DeviceWatcher()
    private var session: ReceiverSession?
    private var sessionTask: Task<Void, Never>?
    private var appearanceObserver: AppearanceObserver?
    /// Block-based observers are only removable through the token
    /// `addObserver` hands back. Discarding them leaves the blocks registered
    /// for the life of the process, firing at a session that has been shut
    /// down.
    private var workspaceObservers: [any NSObjectProtocol] = []
    private var isDarkAppearance = true

    init() {
        let preferences = Preferences()
        self.preferences = preferences
        state = MicState(preferences: preferences)
    }

    /// The menu bar label. Reading `state` and `preferences` here is what makes
    /// Observation re-render the label when the device reports something new.
    var menuBarImage: NSImage {
        MicBadgeIcon.image(kind: state.iconKind, darkAppearance: isDarkAppearance)
    }

    func start() {
        logger.notice("BoyaManager starting")
        isDarkAppearance = NSApp.effectiveAppearance.isDark
        Task { await state.refreshNotificationPermission() }
        appearanceObserver = AppearanceObserver { [weak self] isDark in
            self?.isDarkAppearance = isDark
        }

        let session = ReceiverSession(
            makeLink: { IAP2Link(transport: try USBTransport()) },
            deviceEvents: watcher.events
        )
        self.session = session
        state.attach(to: session)
        sessionTask = Task { await session.run() }
        Task { await watcher.start() }

        observe(NSWorkspace.didWakeNotification) { await $0.recheck() }
        observe(NSWorkspace.sessionDidBecomeActiveNotification) { await $0.recheck() }
        // Nothing is reading a menu bar icon on a display that is off.
        observe(NSWorkspace.screensDidSleepNotification) { await $0.setDisplayAsleep(true) }
        observe(NSWorkspace.screensDidWakeNotification) { await $0.setDisplayAsleep(false) }
    }

    private func observe(_ name: Notification.Name, _ handler: @escaping @Sendable (ReceiverSession) async -> Void) {
        let token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: name, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                guard let session = Shared.controller.session else { return }
                await handler(session)
            }
        }
        workspaceObservers.append(token)
    }

    func stop() async {
        logger.notice("BoyaManager terminating")
        for token in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        workspaceObservers = []
        state.stop()
        await session?.shutdown()
        await watcher.stop()
        sessionTask?.cancel()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Injected so `AppDelegateTests` can drive the termination handshake
    /// without quitting the test runner.
    var shutdown: @MainActor () async -> Void = { await Shared.controller.stop() }
    var replyToTermination: @MainActor (Bool) -> Void = { NSApp.reply(toApplicationShouldTerminate: $0) }
    /// How long the quit path waits for the receiver to be told before giving
    /// up on it. An app that will not quit is worse than an unclean session.
    var terminationTimeout: Duration = .seconds(2)

    /// Set when another instance is already running. That instance never opened
    /// a session, so it has nothing to tell the receiver and must not make the
    /// user wait while it finds that out.
    var isDuplicateInstance = false

    func applicationWillFinishLaunching(_: Notification) {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let alreadyRunning = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .contains { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if alreadyRunning {
            logger.notice("Another instance is already running — deferring to it and quitting")
            isDuplicateInstance = true
            NSApp.terminate(nil)
        }
    }

    func applicationDidFinishLaunching(_: Notification) {
        // LSUIElement covers the bundled app; this covers `swift run`.
        NSApp.setActivationPolicy(.accessory)
        Shared.controller.start()
    }

    /// The receiver has to be told the session is over or it re-enumerates
    /// itself looking for the host again, and telling it takes a round trip.
    ///
    /// `.terminateLater` is the only way to get one. Blocking the main thread
    /// on a semaphore parks the very thread that would run `stop()` — it is
    /// MainActor work — so the wait always times out and the shutdown never
    /// happens at all.
    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        guard !isDuplicateInstance else { return .terminateNow }
        let timeout = terminationTimeout
        Task {
            let quit = OneShot { [self] in replyToTermination(true) }
            let watchdog = Task {
                // `try?` alone swallows the cancellation and would log a
                // timeout on every clean quit.
                do { try await Task.sleep(for: timeout) } catch { return }
                logger.error("Shutdown did not finish in \(timeout.milliseconds, privacy: .public)ms — quitting anyway")
                quit.fire()
            }
            await shutdown()
            watchdog.cancel()
            quit.fire()
        }
        return .terminateLater
    }
}

/// Runs its body at most once. The shutdown and its watchdog race to end the
/// termination handshake and AppKit must be answered exactly once.
@MainActor
private final class OneShot {
    private var body: (() -> Void)?

    init(_ body: @escaping () -> Void) { self.body = body }

    func fire() {
        body?()
        body = nil
    }
}

/// KVO on `NSApp.effectiveAppearance`, so the low-battery icon — which cannot
/// be a template image — is re-rendered when the menu bar flips light or dark.
@MainActor
private final class AppearanceObserver {
    private var observation: NSKeyValueObservation?

    init(onChange: @escaping @MainActor (Bool) -> Void) {
        observation = NSApp.observe(\.effectiveAppearance, options: [.new]) { _, _ in
            Task { @MainActor in onChange(NSApp.effectiveAppearance.isDark) }
        }
    }
}

extension NSAppearance {
    var isDark: Bool {
        bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}
