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
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.openSettings) private var openSettings

    var body: some Scene {
        MenuBarExtra {
            PopoverView(state: Shared.controller.state) {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
        } label: {
            Image(nsImage: Shared.controller.menuBarImage)
                .accessibilityLabel(Shared.controller.state.tooltip)
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
    private var isDarkAppearance = true

    init() {
        let preferences = Preferences()
        self.preferences = preferences
        state = MicState(preferences: preferences)
    }

    /// The menu bar label. Reading `state` and `preferences` here is what makes
    /// Observation re-render the label when the device reports something new.
    var menuBarImage: NSImage {
        MicBadgeIcon.image(
            kind: state.iconKind,
            lowBattery: state.isLowBattery,
            darkAppearance: isDarkAppearance
        )
    }

    func start() {
        logger.notice("BoyaManager starting")
        isDarkAppearance = NSApp.effectiveAppearance.isDark
        appearanceObserver = AppearanceObserver { [weak self] isDark in
            self?.isDarkAppearance = isDark
        }

        let session = ReceiverSession(
            makeLink: { IAP2Link(transport: try USBTransport()) },
            deviceEvents: watcher.events,
            pollInterval: preferences.pollInterval
        )
        self.session = session
        state.attach(to: session)
        sessionTask = Task { await session.run() }
        Task { await watcher.start() }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in await Shared.controller.session?.recheck() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in await Shared.controller.session?.recheck() }
        }
    }

    func stop() async {
        logger.notice("BoyaManager terminating")
        state.stop()
        await session?.shutdown()
        await watcher.stop()
        sessionTask?.cancel()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let alreadyRunning = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .contains { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if alreadyRunning {
            logger.notice("Another instance is already running — deferring to it and quitting")
            NSApp.terminate(nil)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // LSUIElement covers the bundled app; this covers `swift run`.
        NSApp.setActivationPolicy(.accessory)
        Shared.controller.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // The receiver is told the session is over so it does not re-enumerate
        // itself looking for the host again. Capped inside `close()`.
        let done = DispatchSemaphore(value: 0)
        Task {
            await Shared.controller.stop()
            done.signal()
        }
        _ = done.wait(timeout: .now() + 1.5)
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
