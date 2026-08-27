import SwiftUI

/// The menu bar window: what the receiver reports, and every setting that is
/// safe to change from one click away. Risky attributes live in
/// Settings › Advanced and are never reachable from here.
struct PopoverView: View {
    @Bindable var state: MicState
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            transmitters
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Audio")
                controls
            }
            footer
        }
        .padding(14)
        .frame(width: popoverWidth)
        // `MenuBarExtra` has no open/close callback, so the window's own
        // lifetime is the signal. Someone looking at it is the only reason to
        // poll every second.
        .onAppear { state.setPopoverVisible(true) }
        .onDisappear { state.setPopoverVisible(false) }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(state.identity?.model ?? "BOYA mini 2")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            StatusPill(state: state.connection) { state.retry() }
        }
    }

    private var transmitters: some View {
        VStack(spacing: 8) {
            ForEach(state.transmitters, id: \.index) { transmitter in
                TransmitterRow(transmitter: transmitter)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder private var controls: some View {
        LabeledControl(
            title: Attr.noiseCancellation.title,
            isEnabled: state.isEnabled(.noiseCancellation)
        ) {
            if state.isAvailable(.noiseCancellation) {
                Picker("", selection: binding(.noiseCancellation)) {
                    Text("Off").tag(UInt8(0))
                    Text("Weak").tag(UInt8(1))
                    Text("Strong").tag(UInt8(2))
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            } else {
                UnavailableValue()
            }
        }

        // Segmented rather than a slider: the control is bound to the value the
        // device reads back, so it goes inert for a round trip on every change.
        // A slider does that mid-drag and snaps back; six discrete taps do not.
        LabeledControl(title: Attr.rxGain.title, isEnabled: state.isEnabled(.rxGain)) {
            if state.isAvailable(.rxGain) {
                Picker("", selection: binding(.rxGain)) {
                    ForEach(1...6, id: \.self) { level in
                        Text("\(level)").tag(UInt8(level))
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            } else {
                UnavailableValue()
            }
        }

        enumControl(.sceneMode)
        enumControl(.recordingMode)

        LabeledControl(title: Attr.mute.title, isEnabled: state.isEnabled(.mute)) {
            if state.isAvailable(.mute) {
                Toggle("", isOn: flagBinding(.mute))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
            } else {
                UnavailableValue()
            }
        }
    }

    @ViewBuilder
    private func enumControl(_ attr: Attr) -> some View {
        LabeledControl(title: attr.title, isEnabled: state.isEnabled(attr)) {
            if state.isAvailable(attr), let labels = attr.labels {
                Picker("", selection: binding(attr)) {
                    ForEach(labels.keys.sorted(), id: \.self) { value in
                        Text(labels[value] ?? "\(value)").tag(value)
                    }
                }
                .labelsHidden()
            } else {
                UnavailableValue()
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            // A write that timed out or was refused used to re-enable the
            // control at the old value and say nothing at all.
            if let error = state.writeError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let problem = state.connectionProblem {
                // The pill has room for "Failed" and a Retry link, and none at
                // all for why.
                Text(problem)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(action: openSettings) {
                    Label("Settings…", systemImage: "gearshape")
                }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
    }

    /// Every control reads back from the device, never from an optimistic local
    /// value, so a slow write can't make a control flicker between two states.
    private func binding(_ attr: Attr) -> Binding<UInt8> {
        Binding(
            get: { state.value(attr) ?? attr.range?.lowerBound ?? 0 },
            set: { state.set(attr, to: $0) }
        )
    }

    private func flagBinding(_ attr: Attr) -> Binding<Bool> {
        Binding(
            get: { (state.value(attr) ?? 0) != 0 },
            set: { state.set(attr, to: $0 ? 1 : 0) }
        )
    }
}

/// One transmitter. `online` is the only trustworthy flag — the receiver leaves
/// battery and signal at their last-known values when a transmitter is docked,
/// so nothing else is shown while it is offline.
private struct TransmitterRow: View {
    let transmitter: TransmitterState

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: transmitter.isOnline ? "circle.fill" : "circle")
                .font(.system(size: 7))
                .foregroundStyle(transmitter.isOnline ? Color.green : Color.secondary)
                .accessibilityLabel(transmitter.isOnline ? "online" : "offline")
            Text("TX\(transmitter.index)")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 30, alignment: .leading)
            if transmitter.isOnline {
                // Green, and red on the last bar — the same rule the menu bar
                // icon follows, so the two never disagree.
                LevelBars(level: transmitter.battery, tint: transmitter.battery == 1 ? .red : .green)
                if transmitter.charging == 1 {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.green)
                        .accessibilityLabel("charging")
                }
                Text("battery").font(.system(size: 11)).foregroundStyle(.secondary)
                LevelBars(level: transmitter.signal, tint: LevelBars.signal)
                Text("signal").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                if let channel = transmitter.channel {
                    Text(channel == 0 ? "L" : "R")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                }
            } else {
                Text("offline").font(.system(size: 12)).foregroundStyle(.tertiary)
                Spacer()
            }
        }
        .opacity(transmitter.isOnline ? 1 : 0.55)
    }
}
