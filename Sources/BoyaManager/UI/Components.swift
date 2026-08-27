import SwiftUI

/// The popover's fixed geometry. Rows line up because the control column is a
/// constant, not because each control happens to be the size of the one above
/// it. The width is what "Noise Cancellation" needs beside a three-way
/// segmented control without wrapping.
let popoverWidth: CGFloat = 340
let popoverControlWidth: CGFloat = 170

/// A 0…4 bar gauge, the way the receiver reports battery and signal. Unmet bars
/// stay drawn in grey so the gauge keeps its width as the level changes.
struct LevelBars: View {
    /// Drawn rather than left out, so the gauge keeps its width. Any tint near
    /// this one reads as unlit whatever the level says.
    static let unlit = Color.secondary.opacity(0.22)
    /// Signal is the text colour, not `.secondary`: four bars of 55% grey
    /// beside four of 12% grey is a gauge nobody can read, and beside a vivid
    /// green battery it reads as empty at full strength.
    static let signal = Color.primary

    let level: UInt8?
    var count: Int = 4
    var tint: Color = .primary

    var body: some View {
        HStack(spacing: 1.5) {
            ForEach(0..<count, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(index < Int(level ?? 0) ? tint : Self.unlit)
                    .frame(width: 4, height: 5 + CGFloat(index) * 1.5)
            }
        }
        .frame(height: 11, alignment: .bottom)
        .accessibilityLabel(level.map { "\($0) of \(count)" } ?? "unknown")
    }
}

/// Label on the left, control on the right in the fixed column.
struct LabeledControl<Content: View>: View {
    let title: String
    var help: String?
    var isEnabled: Bool = true
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(isEnabled ? .primary : .tertiary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            content
                .controlSize(.small)
                .disabled(!isEnabled)
                .frame(width: popoverControlWidth, alignment: .trailing)
        }
        .help(help ?? "")
    }
}

/// One header for the whole control block, in place of a divider between every
/// pair of rows.
struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .kerning(0.6)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Connection state as a dot and two words, in the header where the eye lands
/// first. It used to be a line of prose in the footer with a ticking timer in
/// it.
struct StatusPill: View {
    let state: ConnectionState
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(tint)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            if case .failed = state {
                Button("Retry", action: retry)
                    .buttonStyle(.link)
                    .font(.system(size: 11))
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var tint: Color {
        switch state {
        case .ready: .green
        case .connecting, .waitingToRetry: .orange
        case .failed: .red
        case .idle: .secondary
        }
    }

    private var label: String {
        switch state {
        case .ready: "Connected"
        case .connecting: "Connecting…"
        case .waitingToRetry(_, _, let seconds): "Retrying in \(seconds)s"
        case .failed: "Failed"
        case .idle: "No receiver"
        }
    }
}

/// The "—" a control shows when the device did not report its attribute — a
/// transmitter-side setting with no transmitter connected, say.
struct UnavailableValue: View {
    var body: some View {
        Text("—")
            .font(.system(size: 13))
            .foregroundStyle(.tertiary)
            .help("The receiver is not reporting this right now. Transmitter-side settings need a connected transmitter.")
    }
}
