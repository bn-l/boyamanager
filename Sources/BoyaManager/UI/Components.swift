import SwiftUI

/// A 0…4 bar gauge, the way the receiver reports battery and signal.
struct LevelBars: View {
    let level: UInt8?
    var count: Int = 4
    var tint: Color = .primary

    var body: some View {
        HStack(spacing: 1.5) {
            ForEach(0..<count, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(index < Int(level ?? 0) ? tint : tint.opacity(0.18))
                    .frame(width: 4, height: 5 + CGFloat(index) * 1.5)
            }
        }
        .frame(height: 11, alignment: .bottom)
        .accessibilityLabel(level.map { "\($0) of \(count)" } ?? "unknown")
    }
}

/// Label on the left, control on the right, with a consistent column width so
/// the popover's rows line up.
struct LabeledControl<Content: View>: View {
    let title: String
    var help: String?
    var isEnabled: Bool = true
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(isEnabled ? .primary : .tertiary)
                .frame(width: 108, alignment: .leading)
            content
                .disabled(!isEnabled)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .help(help ?? "")
    }
}

/// The "—" a control shows when the device did not report its attribute — a
/// transmitter-side setting with no transmitter connected, say.
struct UnavailableValue: View {
    var body: some View {
        Text("—")
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .help("The receiver is not reporting this right now. Transmitter-side settings need a connected transmitter.")
    }
}

struct SectionDivider: View {
    var body: some View {
        Divider().padding(.vertical, 2)
    }
}
