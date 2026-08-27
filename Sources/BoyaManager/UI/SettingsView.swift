import AppKit
import SwiftUI

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
        .frame(width: 460, height: 380)
    }
}

private struct GeneralSettings: View {
    @Bindable var preferences: Preferences
    @Bindable var state: MicState

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $preferences.launchAtLogin)
                // Registration can succeed and still not run: macOS parks it
                // until the user confirms. Saying so beats a toggle that looks
                // on and does nothing.
                if preferences.loginItem == .needsApproval {
                    LabeledContent("") {
                        HStack {
                            Text("Waiting for your approval in System Settings.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
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
                if state.notificationPermission == .denied {
                    LabeledContent("") {
                        HStack {
                            Text("Notifications are turned off for BoyaManager in System Settings.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
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
        .formStyle(.grouped)
        // Both of these can be revoked in System Settings while the app runs,
        // and nothing tells the app about it.
        .onAppear { preferences.refreshLoginItem() }
        .task { await state.refreshNotificationPermission() }
    }
}

private struct DeviceSettings: View {
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
        .formStyle(.grouped)
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
private struct AdvancedSettings: View {
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
        .formStyle(.grouped)
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
