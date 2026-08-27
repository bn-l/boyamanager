import AppKit
import OSLog

private let logger = Logger(subsystem: BoyaLog.subsystem, category: "Icon")

/// The menu bar image: a hollow "B" with the transmitter's battery drawn as
/// bars inside it — a battery gauge shaped like a B — and one dot per online
/// transmitter in the clear column to its right.
///
/// Drawn in white, with alpha carrying every level of grey, and always a
/// template image. That is what a template *is*: the alpha channel is the
/// shape and macOS inks it to suit the menu bar it is sitting on, light or
/// dark, highlighted or not. Colour cannot survive that, and colour is the
/// only thing the app used to guess an appearance for.
enum MicBadgeIcon {
    /// Not square: the dots live in their own column so they never have to be
    /// knocked out of the letter.
    static let width: CGFloat = 21
    static let height: CGFloat = 18
    /// The level at which the app calls the battery low. The icon shows it as
    /// the one bar it is; the rest of the app takes the rule from here so the
    /// warning and the drawing agree.
    static let lowBatteryLevel: UInt8 = 1

    enum Kind: Sendable, Equatable {
        /// A transmitter is online: 0…4 bars, plus how many transmitters are
        /// online at all. The dots are a count, not a which.
        case level(UInt8, online: Int)
        /// Receiver connected, no transmitter online.
        case offline
        /// No receiver.
        case disconnected
        case connecting
    }

    static func image(kind: Kind) -> NSImage {
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else {
                logger.error("No CGContext available for the badge")
                return false
            }
            // The handler can run inside someone else's context when this gets
            // composited, so never leak clip or alpha state.
            context.saveGState()
            defer { context.restoreGState() }

            let ink = inkColor(kind: kind)
            ink.setStroke()
            Geometry.outline.stroke()

            if let level = kind.level, level > 0 {
                ink.setFill()
                for bar in Geometry.bars.prefix(Int(min(level, 4))) {
                    NSBezierPath(roundedRect: bar, xRadius: Geometry.barRadius, yRadius: Geometry.barRadius).fill()
                }
            }

            ink.setFill()
            for centre in Geometry.dotCentres.prefix(kind.onlineCount) {
                NSBezierPath(circleAt: centre, radius: Geometry.dotRadius).fill()
            }

            if kind == .disconnected {
                // Punch a gap under the strike so it reads as a slash rather
                // than an extra piece of the letter.
                context.saveGState()
                context.setBlendMode(.destinationOut)
                strikePath(width: 3.4).stroke()
                context.restoreGState()
                ink.setStroke()
                strikePath(width: 1.5).stroke()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = kind.accessibilityDescription
        return image
    }

    /// White throughout; the state is in the alpha.
    private static func inkColor(kind: Kind) -> NSColor {
        let alpha: CGFloat
        switch kind {
        case .level: alpha = 1
        case .offline: alpha = 0.6
        case .disconnected, .connecting: alpha = 0.4
        }
        return NSColor(white: 1, alpha: alpha)
    }

    /// Across the letter, not across the canvas — the dot column stays clear.
    private static func strikePath(width strokeWidth: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: CGPoint(x: 1.5, y: 2.5))
        path.line(to: CGPoint(x: height - 1.5, y: height - 2.5))
        path.lineWidth = strokeWidth
        path.lineCapStyle = .round
        return path
    }

    /// The letter as one closed stroke — stem, top edge, upper lobe, the waist
    /// notch, lower lobe, bottom edge — enclosing a single hollow. There is no
    /// horizontal bar across the middle, so the bars inside need no clipping:
    /// they simply stop short of the lobes.
    enum Geometry {
        static let stroke: CGFloat = 1.6
        /// Centre line of the stem. The outer edge is half a stroke to its left.
        static let stemX: CGFloat = 3.8
        static let topY: CGFloat = 16.2
        static let bottomY: CGFloat = 1.8
        static let waistY: CGFloat = 9.4
        /// Where the straight top and bottom edges give way to the lobes.
        static let topEdgeEnd: CGFloat = 9.6
        static let bottomEdgeEnd: CGFloat = 10.2
        /// The lower lobe of a B is the wider one. Where the two meet, the
        /// outline steps in and back out — the notch, on the outside only.
        static let upperRight: CGFloat = 14.3
        static let lowerRight: CGFloat = 15.2
        static let waistX: CGFloat = 11.6
        /// The furthest right the letter is drawn, half a stroke past the lobe.
        static var letterRight: CGFloat { lowerRight + stroke / 2 }

        static let barLeft: CGFloat = 5.9
        static let barRight: CGFloat = 10.6
        static let barHeight: CGFloat = 1.7
        static let barGap: CGFloat = 0.95
        static let barRadius: CGFloat = 0.4

        static let dotRadius: CGFloat = 2
        /// Top-right, in the column the letter does not reach, and the second
        /// directly below it. Clear of the lobe, so neither needs knocking out
        /// of the stroke to read as a dot.
        static let dotCentres = [CGPoint(x: 18.6, y: 15.6), CGPoint(x: 18.6, y: 11)]

        static var outline: NSBezierPath {
            let path = NSBezierPath()
            path.move(to: CGPoint(x: stemX, y: bottomY))
            path.line(to: CGPoint(x: stemX, y: topY))
            path.line(to: CGPoint(x: topEdgeEnd, y: topY))
            path.quarter(to: CGPoint(x: upperRight, y: (topY + waistY) / 2), corner: CGPoint(x: upperRight, y: topY))
            path.quarter(to: CGPoint(x: waistX, y: waistY), corner: CGPoint(x: upperRight, y: waistY))
            path.quarter(to: CGPoint(x: lowerRight, y: (waistY + bottomY) / 2), corner: CGPoint(x: lowerRight, y: waistY))
            path.quarter(to: CGPoint(x: bottomEdgeEnd, y: bottomY), corner: CGPoint(x: lowerRight, y: bottomY))
            path.close()
            path.lineWidth = stroke
            path.lineJoinStyle = .round
            path.lineCapStyle = .round
            return path
        }

        /// Four bars of equal width and height, filling from the bottom, the
        /// block centred in the hollow. Equal because the gauge reads as a
        /// gauge; short of the lobes because nothing should need clipping.
        static var bars: [CGRect] {
            let block = barHeight * 4 + barGap * 3
            let floor = bottomY + stroke / 2
            let ceiling = topY - stroke / 2
            let start = floor + (ceiling - floor - block) / 2
            return (0..<4).map { index in
                CGRect(
                    x: barLeft,
                    y: start + (barHeight + barGap) * CGFloat(index),
                    width: barRight - barLeft,
                    height: barHeight
                )
            }
        }
    }
}

extension NSBezierPath {
    /// One quarter of an ellipse as a single cubic. `corner` is where the two
    /// tangents meet — the square corner the arc bulges into.
    fileprivate func quarter(to end: CGPoint, corner: CGPoint) {
        let bulge: CGFloat = 0.5523
        let start = currentPoint
        curve(
            to: end,
            controlPoint1: CGPoint(x: start.x + (corner.x - start.x) * bulge, y: start.y + (corner.y - start.y) * bulge),
            controlPoint2: CGPoint(x: end.x + (corner.x - end.x) * bulge, y: end.y + (corner.y - end.y) * bulge)
        )
    }

    fileprivate convenience init(circleAt centre: CGPoint, radius: CGFloat) {
        self.init(ovalIn: CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2))
    }
}

extension MicBadgeIcon.Kind {
    var isLevel: Bool {
        if case .level = self { return true }
        return false
    }

    var level: UInt8? {
        if case .level(let level, _) = self { return level }
        return nil
    }

    var onlineCount: Int {
        if case .level(_, let online) = self { return max(0, online) }
        return 0
    }

    var accessibilityDescription: String {
        switch self {
        case let .level(level, online):
            "BOYA mic battery \(level) of 4, \(online) transmitter\(online == 1 ? "" : "s") online"
        case .offline: "BOYA mic offline"
        case .disconnected: "BOYA receiver not connected"
        case .connecting: "BOYA receiver connecting"
        }
    }
}

extension MicBadgeIcon {
    /// Debug helper (`--render-icons <dir>`): writes 8× PNGs of every state on a
    /// menu-bar-like background. This is how the geometry gets tuned and how a
    /// regression gets spotted.
    static func writePreviews(to directory: URL) {
        struct Sample {
            let kind: Kind
            let dark: Bool
            var name: String {
                let base = switch kind {
                case let .level(level, online): "level\(level)-online\(online)"
                case .offline: "offline"
                case .disconnected: "disconnected"
                case .connecting: "connecting"
                }
                return "b-\(base)-\(dark ? "dark" : "light").png"
            }
        }

        var samples: [Sample] = []
        for dark in [true, false] {
            for level in UInt8(0)...4 {
                samples.append(Sample(kind: .level(level, online: 1), dark: dark))
            }
            samples.append(Sample(kind: .level(3, online: 2), dark: dark))
            samples.append(Sample(kind: .level(1, online: 2), dark: dark))
            samples.append(Sample(kind: .level(2, online: 0), dark: dark))
            samples.append(Sample(kind: .offline, dark: dark))
            samples.append(Sample(kind: .disconnected, dark: dark))
            samples.append(Sample(kind: .connecting, dark: dark))
        }

        let scale: CGFloat = 8
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for sample in samples {
                let badge = image(kind: sample.kind)
                // Rasterize before compositing — drawing a live handler-backed
                // image inside another one distorts its coordinates.
                guard let badgeData = badge.tiffRepresentation, let bitmap = NSImage(data: badgeData) else {
                    logger.error("Badge rasterize failed for \(sample.name, privacy: .public)")
                    continue
                }
                // A template image is alpha only; tint it the way the menu bar
                // would before compositing, or it is invisible on the preview.
                let tinted = NSImage(size: bitmap.size, flipped: false) { rect in
                    bitmap.draw(in: rect)
                    (sample.dark ? NSColor.white : NSColor.black).set()
                    rect.fill(using: .sourceAtop)
                    return true
                }

                let canvasSize = NSSize(width: width * scale, height: height * scale)
                let canvas = NSImage(size: canvasSize, flipped: false) { rect in
                    NSColor(white: sample.dark ? 0.15 : 0.85, alpha: 1).setFill()
                    rect.fill()
                    NSGraphicsContext.current?.imageInterpolation = .none
                    tinted.draw(in: rect.insetBy(dx: width, dy: height))
                    return true
                }
                guard let tiff = canvas.tiffRepresentation,
                      let representation = NSBitmapImageRep(data: tiff),
                      let png = representation.representation(using: .png, properties: [:]) else {
                    logger.error("Preview encode failed for \(sample.name, privacy: .public)")
                    continue
                }
                try png.write(to: directory.appending(path: sample.name))
            }
            logger.notice("Wrote \(samples.count, privacy: .public) icon previews to \(directory.path, privacy: .public)")
        } catch {
            logger.error("Preview write failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
