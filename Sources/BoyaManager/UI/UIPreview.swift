import AppKit
import OSLog
import SwiftUI

private let logger = Logger(subsystem: BoyaLog.subsystem, category: "UI")

/// Debug helper (`--render-ui <dir>`): snapshots the popover and the settings
/// tabs against a canned receiver state, so layout can be checked without
/// clicking through a menu bar item.
@MainActor
enum UIPreview {
    /// The receiver as captured on hardware: TX2 online at 3 bars, TX1 docked,
    /// noise cancellation strong, gain 4.
    private static var sampleSnapshot: AttributeSnapshot {
        AttributeSnapshot(status: 0, values: [
            1: [0], 2: [0], 4: [0], 7: [0],
            21: [3], 22: [0], 24: [4], 27: [1],
            41: [0], 42: [0, 0, 0, 0, 0, 0], 44: [1], 45: [1], 47: [2], 48: [0],
            61: [4], 62: [2], 63: [0], 64: [1], 65: [4], 67: [1], 68: [0], 69: [1], 71: [0],
        ])
    }

    /// Both transmitters online, one of them down to its last bar — the state
    /// the popover has the most to draw for.
    private static var bothOnlineSnapshot: AttributeSnapshot {
        var values = sampleSnapshot.values
        values[Attr.tx1Online.rawValue] = [1]
        values[Attr.tx1Battery.rawValue] = [1]
        values[Attr.tx1Signal.rawValue] = [3]
        values[Attr.tx1Charging.rawValue] = [1]
        return AttributeSnapshot(status: 0, values: values)
    }

    static func write(to directory: URL) {
        _ = NSApplication.shared
        let defaults = UserDefaults(suiteName: "boya-manager-preview") ?? .standard
        let preferences = Preferences(defaults: defaults)
        let size = NSSize(width: popoverWidth, height: 330)

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try render(popover(preferences, sampleSnapshot), size: size, to: directory.appending(path: "popover.png"))
            try render(popover(preferences, bothOnlineSnapshot), size: size, to: directory.appending(path: "popover-two-transmitters.png"))

            let state = MicState(preferences: preferences)
            state.apply(.state(.ready))
            state.apply(.identified(previewIdentity))
            state.apply(.snapshot(sampleSnapshot))
            try render(
                SettingsView(preferences: preferences, state: state),
                size: NSSize(width: 460, height: 380),
                to: directory.appending(path: "settings.png")
            )

            let disconnected = MicState(preferences: preferences)
            disconnected.apply(.state(.failed(.claimFailed)))
            try render(PopoverView(state: disconnected) {}, size: size, to: directory.appending(path: "popover-disconnected.png"))
            logger.notice("Wrote UI previews to \(directory.path, privacy: .public)")
        } catch {
            logger.error("UI preview failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func popover(_ preferences: Preferences, _ snapshot: AttributeSnapshot) -> PopoverView {
        let state = MicState(preferences: preferences)
        state.apply(.state(.ready))
        state.apply(.identified(previewIdentity))
        state.apply(.snapshot(snapshot))
        return PopoverView(state: state) {}
    }

    private static var previewIdentity: DeviceIdentity {
        var identity = DeviceIdentity()
        identity.model = "BOYA mini 2"
        identity.serial = "CFD7387E79"
        identity.firmware = "1.1.0"
        identity.hardware = "1.1.0"
        identity.manufacturer = "Shenzhen jiayz photo industrial ltd"
        identity.protocols = [EAProtocol(id: 177, name: BoyaDevice.externalAccessoryProtocol)]
        return identity
    }

    /// Renders through a real window's layer tree rather than
    /// `cacheDisplay(in:to:)`, which comes back nearly empty for SwiftUI —
    /// most of the content lives in backing layers that a display-cache pass
    /// never visits.
    private static func render(_ view: some View, size: NSSize, to url: URL) throws {
        let window = NSWindow(
            contentRect: NSRect(origin: CGPoint(x: -5_000, y: -5_000), size: size),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        window.contentView = hosting
        window.orderFront(nil)
        RunLoop.current.run(until: .now + 0.8)

        guard let layer = hosting.layer else { throw CocoaError(.fileWriteUnknown) }
        let scale = window.backingScaleFactor
        guard let context = CGContext(
            data: nil,
            width: Int(size.width * scale),
            height: Int(size.height * scale),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { throw CocoaError(.fileWriteUnknown) }
        context.setFillColor(NSColor.windowBackgroundColor.cgColor)
        context.fill(CGRect(origin: .zero, size: CGSize(width: size.width * scale, height: size.height * scale)))
        // CGContext is bottom-left origin, layers are top-left.
        context.translateBy(x: 0, y: size.height * scale)
        context.scaleBy(x: scale, y: -scale)
        layer.render(in: context)

        guard let image = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        let representation = NSBitmapImageRep(cgImage: image)
        guard let png = representation.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try png.write(to: url)
        window.close()
    }
}
