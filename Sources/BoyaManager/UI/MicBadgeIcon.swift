import AppKit
import OSLog

private let logger = Logger(subsystem: BoyaLog.subsystem, category: "Icon")

/// The menu bar image: a hollow "B" with the transmitter's battery drawn as
/// bars inside it — a battery gauge shaped like a B.
///
/// Normally a template image (alpha only) so macOS paints it correctly on light
/// and dark menu bars and handles click highlighting. A low battery can't be a
/// template — templates lose colour — so in that one state the outline is drawn
/// in the appearance colour itself and the bars in red.
enum MicBadgeIcon {
    static let size: CGFloat = 18

    enum Kind: Sendable, Equatable {
        /// A transmitter is online; 0…4 bars.
        case level(UInt8)
        /// Receiver connected, no transmitter online.
        case offline
        /// No receiver.
        case disconnected
        case connecting
    }

    static func image(kind: Kind, lowBattery: Bool = false, darkAppearance: Bool = true) -> NSImage {
        let coloured = lowBattery && kind.isLevel
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else {
                logger.error("No CGContext available for the badge")
                return false
            }
            // The handler can run inside someone else's context when this gets
            // composited, so never leak clip or alpha state.
            context.saveGState()
            defer { context.restoreGState() }

            let ink = inkColor(kind: kind, coloured: coloured, darkAppearance: darkAppearance)
            ink.setFill()
            Geometry.outline.fill()

            if case .level(let level) = kind, level > 0 {
                context.saveGState()
                Geometry.counters.addClip()
                (coloured ? NSColor.systemRed : ink).setFill()
                for bar in Geometry.bars.prefix(Int(min(level, 4))) {
                    NSBezierPath(rect: bar).fill()
                }
                context.restoreGState()
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
        image.isTemplate = !coloured
        image.accessibilityDescription = kind.accessibilityDescription
        return image
    }

    private static func inkColor(kind: Kind, coloured: Bool, darkAppearance: Bool) -> NSColor {
        let alpha: CGFloat
        switch kind {
        case .level: alpha = 1
        case .offline: alpha = 0.6
        case .disconnected, .connecting: alpha = 0.4
        }
        guard coloured else { return NSColor(white: 0, alpha: alpha) }
        return (darkAppearance ? NSColor.white : NSColor.black).withAlphaComponent(alpha)
    }

    private static func strikePath(width: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: CGPoint(x: 1.5, y: 2.5))
        path.line(to: CGPoint(x: size - 1.5, y: size - 2.5))
        path.lineWidth = width
        path.lineCapStyle = .round
        return path
    }

    /// The letter, hand-built rather than typeset: a stem plus two "D" lobes,
    /// each lobe a filled outer shape with a reversed inner shape punched out of
    /// it by the non-zero winding rule. Building it this way means the counters
    /// — the two holes — are known paths, so the bars can be clipped exactly to
    /// them instead of being fudged with insets.
    enum Geometry {
        static let stroke: CGFloat = 1.6
        static let left: CGFloat = 2.0
        static let bottom: CGFloat = 1.6
        static let top: CGFloat = 16.4
        static let waist: CGFloat = 9.5
        /// The lower lobe of a B is the wider one.
        static let upperRight: CGFloat = 13.0
        static let lowerRight: CGFloat = 15.0

        static let upperCounter = CGRect(
            x: left + stroke, y: waist + stroke / 2,
            width: (upperRight - stroke) - (left + stroke), height: (top - stroke) - (waist + stroke / 2)
        )
        static let lowerCounter = CGRect(
            x: left + stroke, y: bottom + stroke,
            width: (lowerRight - stroke) - (left + stroke), height: (waist - stroke / 2) - (bottom + stroke)
        )

        static var outline: NSBezierPath {
            let path = NSBezierPath()
            path.windingRule = .nonZero
            path.appendRect(CGRect(x: left, y: bottom, width: stroke, height: top - bottom))
            path.append(lobe(left: left, right: upperRight, bottom: waist, top: top, reversed: false))
            path.append(lobe(rect: upperCounter, reversed: true))
            path.append(lobe(left: left, right: lowerRight, bottom: bottom, top: waist, reversed: false))
            path.append(lobe(rect: lowerCounter, reversed: true))
            return path
        }

        static var counters: NSBezierPath {
            let path = NSBezierPath()
            path.append(lobe(rect: upperCounter, reversed: false))
            path.append(lobe(rect: lowerCounter, reversed: false))
            return path
        }

        /// Four bars, two per counter, filling from the bottom. Each spans the
        /// full canvas width and is clipped to the counters, so the lower pair
        /// come out longer — the gauge widens as it fills, like the letter does.
        static var bars: [CGRect] {
            [
                bar(in: lowerCounter, index: 0, of: 2),
                bar(in: lowerCounter, index: 1, of: 2),
                bar(in: upperCounter, index: 0, of: 2),
                bar(in: upperCounter, index: 1, of: 2),
            ]
        }

        private static func bar(in counter: CGRect, index: Int, of count: Int) -> CGRect {
            let gap: CGFloat = 1.0
            let height = (counter.height - gap * CGFloat(count - 1)) / CGFloat(count)
            return CGRect(
                x: 0, y: counter.minY + (height + gap) * CGFloat(index),
                width: size, height: height
            )
        }

        private static func lobe(rect: CGRect, reversed: Bool) -> NSBezierPath {
            lobe(left: rect.minX, right: rect.maxX, bottom: rect.minY, top: rect.maxY, reversed: reversed)
        }

        /// A "D": flat on the left, semicircular on the right. Wound
        /// counter-clockwise unless `reversed`, which is what turns it into a
        /// hole under the non-zero rule.
        private static func lobe(left: CGFloat, right: CGFloat, bottom: CGFloat, top: CGFloat, reversed: Bool) -> NSBezierPath {
            let path = NSBezierPath()
            let radius = (top - bottom) / 2
            let center = CGPoint(x: max(left, right - radius), y: (top + bottom) / 2)
            if reversed {
                path.move(to: CGPoint(x: left, y: top))
                path.line(to: CGPoint(x: center.x, y: top))
                path.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: -90, clockwise: true)
                path.line(to: CGPoint(x: left, y: bottom))
            } else {
                path.move(to: CGPoint(x: left, y: bottom))
                path.line(to: CGPoint(x: center.x, y: bottom))
                path.appendArc(withCenter: center, radius: radius, startAngle: -90, endAngle: 90, clockwise: false)
                path.line(to: CGPoint(x: left, y: top))
            }
            path.close()
            return path
        }
    }
}

extension MicBadgeIcon.Kind {
    var isLevel: Bool {
        if case .level = self { return true }
        return false
    }

    var accessibilityDescription: String {
        switch self {
        case .level(let level): "BOYA mic battery \(level) of 4"
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
            let low: Bool
            let dark: Bool
            var name: String {
                let base = switch kind {
                case .level(let level): "level\(level)"
                case .offline: "offline"
                case .disconnected: "disconnected"
                case .connecting: "connecting"
                }
                return "b-\(base)\(low ? "-low" : "")-\(dark ? "dark" : "light").png"
            }
        }

        var samples: [Sample] = []
        for dark in [true, false] {
            for level in UInt8(0)...4 {
                samples.append(Sample(kind: .level(level), low: false, dark: dark))
            }
            samples.append(Sample(kind: .level(1), low: true, dark: dark))
            samples.append(Sample(kind: .offline, low: false, dark: dark))
            samples.append(Sample(kind: .disconnected, low: false, dark: dark))
            samples.append(Sample(kind: .connecting, low: false, dark: dark))
        }

        let scale: CGFloat = 8
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for sample in samples {
                let badge = image(kind: sample.kind, lowBattery: sample.low, darkAppearance: sample.dark)
                // Rasterize before compositing — drawing a live handler-backed
                // image inside another one distorts its coordinates.
                guard let badgeData = badge.tiffRepresentation, let bitmap = NSImage(data: badgeData) else {
                    logger.error("Badge rasterize failed for \(sample.name, privacy: .public)")
                    continue
                }
                // A template image is alpha only; tint it the way the menu bar
                // would before compositing, or it is invisible on the preview.
                let tinted = badge.isTemplate
                    ? NSImage(size: bitmap.size, flipped: false) { rect in
                        bitmap.draw(in: rect)
                        (sample.dark ? NSColor.white : NSColor.black).set()
                        rect.fill(using: .sourceAtop)
                        return true
                    }
                    : bitmap

                let edge = size * scale
                let canvas = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
                    NSColor(white: sample.dark ? 0.15 : 0.85, alpha: 1).setFill()
                    rect.fill()
                    NSGraphicsContext.current?.imageInterpolation = .none
                    tinted.draw(in: rect.insetBy(dx: size, dy: size))
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
