import SwiftUI

/// The menu bar window: what the receiver reports, and every setting that is
/// safe to change from one click away. Risky attributes live in
/// Settings › Advanced and are never reachable from here.
struct PopoverView: View {
    @Bindable var state: MicState
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            SectionDivider()
            ForEach(state.transmitters, id: \.index) { transmitter in
                TransmitterRow(transmitter: transmitter)
            }
            SectionDivider()
            controls
            SectionDivider()
            footer
        }
        .padding(12)
        .frame(width: 320)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(state.identity?.model ?? "BOYA mini 2")
                    .font(.system(size: 13, weight: .semibold))
                HStack(spacing: 6) {
                    Text("Receiver").font(.system(size: 11)).foregroundStyle(.secondary)
                    LevelBars(level: state.receiver.battery, tint: .secondary)
                    Text(receiverDetail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(action: openSettings) {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings")
            Button { NSApplication.shared.terminate(nil) } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.borderless)
            .help("Quit BoyaManager")
        }
    }

    private var receiverDetail: String {
        var parts: [String] = []
        if let charging = state.receiver.charging, let label = Attr.rxCharging.labels?[charging], charging != 0 {
            parts.append(label.lowercased())
        }
        if let firmware = state.identity?.firmware { parts.append("v\(firmware)") }
        return parts.joined(separator: " · ")
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
                .frame(width: 170)
            } else {
                UnavailableValue()
            }
        }

        LabeledControl(title: Attr.rxGain.title, isEnabled: state.isEnabled(.rxGain)) {
            if state.isAvailable(.rxGain) {
                HStack(spacing: 6) {
                    Slider(value: gainBinding, in: 1...6, step: 1)
                        .frame(width: 140)
                    Text("\(state.value(.rxGain) ?? 0)")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 14, alignment: .trailing)
                }
            } else {
                UnavailableValue()
            }
        }

        enumControl(.sceneMode)
        enumControl(.recordingMode)

        LabeledControl(title: Attr.mute.title, isEnabled: state.isEnabled(.mute)) {
            if state.isAvailable(.mute) {
                Toggle("", isOn: flagBinding(.mute)).labelsHidden().toggleStyle(.switch).controlSize(.mini)
            } else {
                UnavailableValue()
            }
        }

    }

    @ViewBuilder private func enumControl(_ attr: Attr) -> some View {
        LabeledControl(title: attr.title, isEnabled: state.isEnabled(attr)) {
            if state.isAvailable(attr), let labels = attr.labels {
                Picker("", selection: binding(attr)) {
                    ForEach(labels.keys.sorted(), id: \.self) { value in
                        Text(labels[value] ?? "\(value)").tag(value)
                    }
                }
                .labelsHidden()
                .frame(width: 170)
            } else {
                UnavailableValue()
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Text(state.statusLine)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer()
            if case .failed = state.connection {
                Button("Retry") { state.retry() }
                    .buttonStyle(.link)
                    .font(.system(size: 10))
            }
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

    private var gainBinding: Binding<Double> {
        Binding(
            get: { Double(state.value(.rxGain) ?? 1) },
            set: { state.set(.rxGain, to: UInt8($0.rounded())) }
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
            Text("TX\(transmitter.index)")
                .font(.system(size: 11, weight: .medium))
                .frame(width: 30, alignment: .leading)
            if transmitter.isOnline {
                LevelBars(level: transmitter.battery)
                Text("battery").font(.system(size: 10)).foregroundStyle(.secondary)
                LevelBars(level: transmitter.signal, tint: .secondary)
                Text("signal").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                if let channel = transmitter.channel {
                    Text(channel == 0 ? "L" : "R")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("offline").font(.system(size: 11)).foregroundStyle(.tertiary)
                Spacer()
            }
        }
        .opacity(transmitter.isOnline ? 1 : 0.55)
    }
}
