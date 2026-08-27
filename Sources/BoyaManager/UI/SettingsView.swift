import AppKit
import SwiftUI

/// The tab strip is the toolbar every other settings window on the system has,
/// and a `TabView` only draws itself that way inside a `Settings` scene. In a
/// window of our own it comes out as a row of segmented pills, which is why
/// this is not a window of our own.
struct SettingsView: View {
    @Bindable var preferences: Preferences
    @Bindable var state: MicState

    var body: some View {
        TabView {
            GeneralSettings(preferences: preferences, state: state)
                .tabItem { Label("General", systemImage: "gearshape") }
            DeviceSettings(state: state)
                .tabItem { Label("Device", systemImage: "antenna.radiowaves.left.and.right") }
            AdvancedSettings(state: state)
                .tabItem { Label("Advanced", systemImage: "exclamationmark.triangle") }
        }
    }
}

/// Settings panes size themselves and the window follows, the way System
/// Settings does.
///
/// A fixed height gave every tab the same one — the tallest tab scrolled,
/// because a grouped `Form` is a list-backed scroll view, with the overlay
/// scroller drawn across the inset sections; and stating a height per pane
/// only moved the problem, because the tab bar comes out of that height and
/// the last card ended up against the bottom edge. `fixedSize` lets the form
/// state what it needs and the window takes it from there.
private let settingsWidth: CGFloat = 460

extension View {
    fileprivate func settingsPane() -> some View {
        formStyle(.grouped)
            .scrollDisabled(true)
            .frame(width: settingsWidth)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Rendered on its own by `--render-ui`, which is how the pane heights get
/// checked, so these are not private.
struct GeneralSettings: View {
    @Bindable var preferences: Preferences
    @Bindable var state: MicState

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $preferences.launchAtLogin)
                // Registration can succeed and still not run: macOS parks it
                // until the user confirms. A permanent line rather than one
                // that appears when it has something to say — a row that comes
                // and goes changes the height of a pane that has a fixed one.
                LabeledContent("Status") {
                    HStack {
                        Text(loginStatus).font(.caption).foregroundStyle(.secondary)
                        if preferences.loginItem == .needsApproval {
                            Button("Open Login Items…") { preferences.openLoginItemsSettings() }
                        }
                    }
                }
            }

            Section("Notifications") {
                Toggle("Show notifications", isOn: $preferences.notificationsEnabled)
                    .onChange(of: preferences.notificationsEnabled) { _, enabled in
                        guard enabled else { return }
                        Task { await state.enableNotifications() }
                    }
                // Switching the toggle on cannot override a refusal, and the
                // app has no way to ask again once it has been made.
                LabeledContent("Permission") {
                    HStack {
                        Text(notificationStatus).font(.caption).foregroundStyle(.secondary)
                        if state.notificationPermission == .denied {
                            Button("Open…") { state.openNotificationSettings() }
                        }
                    }
                }
                Toggle("Transmitter battery is low", isOn: $preferences.notifyLowBattery)
                    .disabled(!preferences.notificationsEnabled)
                Toggle("A transmitter connects or disconnects", isOn: $preferences.notifyTransmitterPresence)
                    .disabled(!preferences.notificationsEnabled)
                Toggle("The receiver disconnects", isOn: $preferences.notifyReceiverDisconnected)
                    .disabled(!preferences.notificationsEnabled)
            }

            Section {
                LabeledContent("Version", value: Bundle.main.shortVersion)
                HStack {
                    Spacer()
                    Button("Quit BoyaManager") { NSApplication.shared.terminate(nil) }
                }
            }
        }
        .settingsPane()
        // Both of these can be revoked in System Settings while the app runs,
        // and nothing tells the app about it.
        .onAppear { preferences.refreshLoginItem() }
        .task { await state.refreshNotificationPermission() }
    }

    private var loginStatus: String {
        switch preferences.loginItem {
        case .on: "Registered."
        case .off: "Not registered."
        case .needsApproval: "Waiting for your approval in System Settings."
        }
    }

    private var notificationStatus: String {
        switch state.notificationPermission {
        case .allowed: "Allowed."
        case .denied: "Turned off for BoyaManager in System Settings."
        case .undetermined: "Not asked yet — the first one will ask."
        }
    }
}

/// Rendered on its own by `--render-ui`, which is how the pane heights get
/// checked, so these are not private.
struct DeviceSettings: View {
    @Bindable var state: MicState

    var body: some View {
        Form {
            Section("Receiver") {
                LabeledContent("Model", value: state.identity?.model ?? "—")
                LabeledContent("Serial", value: state.identity?.serial ?? "—")
                LabeledContent("Firmware", value: state.identity?.firmware ?? "—")
                LabeledContent("Hardware", value: state.identity?.hardware ?? "—")
                LabeledContent("Manufacturer", value: state.identity?.manufacturer ?? "—")
            }

            Section("Settings") {
                AttributeToggle(state: state, attr: .txIndicatorLights)
                AttributeToggle(state: state, attr: .txAutoPowerOff)
                AttributeToggle(state: state, attr: .rxAutoPowerOff)
            }

            Section {
                Text(state.statusLine).font(.caption).foregroundStyle(.secondary)
            }
        }
        .settingsPane()
    }
}

private struct AttributeToggle: View {
    @Bindable var state: MicState
    let attr: Attr

    var body: some View {
        Toggle(attr.title, isOn: Binding(
            get: { (state.value(attr) ?? 0) != 0 },
            set: { state.set(attr, to: $0 ? 1 : 0) }
        ))
        .disabled(!state.isEnabled(attr))
    }
}

/// Everything here has a consequence beyond changing a setting, so each action
/// spells out what it does and asks first. These are the only callers of
/// `MicState.setRisky`.
/// Rendered on its own by `--render-ui`, which is how the pane heights get
/// checked, so these are not private.
struct AdvancedSettings: View {
    @Bindable var state: MicState
    @State private var confirming: Attr?
    @State private var confirmingReset = false

    var body: some View {
        Form {
            Section {
                Text("These change the receiver itself. They are here rather than in the menu because a mis-click costs more than a setting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // No pairing button: rx_pair_en (70) is not implemented on a mini 2
            // — the device answers status 1 and the id is absent from its
            // metadata (PROTOCOL.md §9.6). A control that can only fail is
            // worse than no control.
            Section("Speaker mode") {
                Button(speakerButtonTitle) { confirming = .rxSpeaker }
                    .disabled(!state.isEnabled(.rxSpeaker))
                Text(Attr.rxSpeaker.riskWarning ?? "").font(.caption).foregroundStyle(.secondary)
            }

            Section("Factory reset") {
                Button("Reset the receiver…", role: .destructive) { confirming = .rxReset }
                    .disabled(!state.connection.isReady)
                Text(Attr.rxReset.riskWarning ?? "").font(.caption).foregroundStyle(.secondary)
            }
        }
        .settingsPane()
        .confirmationDialog(
            confirming?.title ?? "",
            isPresented: Binding(get: { confirming != nil && !confirmingReset }, set: { if !$0 { confirming = nil } }),
            titleVisibility: .visible
        ) {
            if let attr = confirming {
                Button(attr == .rxReset ? "Continue" : "Change", role: attr == .rxReset ? .destructive : nil) {
                    if attr == .rxReset {
                        confirmingReset = true
                    } else {
                        apply(attr)
                        confirming = nil
                    }
                }
                Button("Cancel", role: .cancel) { confirming = nil }
            }
        } message: {
            Text(confirming?.riskWarning ?? "")
        }
        .confirmationDialog("Reset the receiver to factory defaults?", isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("Reset", role: .destructive) {
                state.setRisky(.rxReset, to: 1)
                confirming = nil
            }
            Button("Cancel", role: .cancel) { confirming = nil }
        } message: {
            Text("Every setting on the receiver goes back to its default and the paired transmitters may need pairing again. This cannot be undone.")
        }
    }

    private var speakerButtonTitle: String {
        (state.value(.rxSpeaker) ?? 0) != 0 ? "Turn the speaker off…" : "Turn the speaker on…"
    }

    private func apply(_ attr: Attr) {
        switch attr {
        case .rxSpeaker: state.setRisky(.rxSpeaker, to: (state.value(.rxSpeaker) ?? 0) != 0 ? 0 : 1)
        default: break
        }
    }
}

extension Bundle {
    var shortVersion: String {
        (object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "dev"
    }
}
