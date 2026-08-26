import AppKit
@testable import BoyaManager
import Testing

@Suite("Menu bar icon")
struct MicBadgeIconTests {
    /// Rasterizes the badge at 4× and samples it in the icon's own coordinate
    /// space (0…18, origin bottom-left), so the tests read like the geometry
    /// does. 4× rather than the image's own 1× because a bar is 1.7 pt tall:
    /// at one pixel per point every sample near an edge lands half-covered and
    /// says nothing about whether the shape is right.
    private static let scale = 4

    private func sampler(_ image: NSImage) throws -> (rep: NSBitmapImageRep, at: (CGFloat, CGFloat) -> NSColor?) {
        let size = MicBadgeIcon.size
        let pixels = Int(size) * Self.scale
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixels,
            pixelsHigh: pixels,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        rep.size = NSSize(width: size, height: size)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()

        let at: (CGFloat, CGFloat) -> NSColor? = { x, y in
            let px = min(pixels - 1, max(0, Int(x / size * CGFloat(pixels))))
            let py = min(pixels - 1, max(0, Int((size - y) / size * CGFloat(pixels))))
            return rep.colorAt(x: px, y: py)?.usingColorSpace(.sRGB)
        }
        return (rep, at)
    }

    /// How far the ink actually runs along one horizontal line, in points.
    /// Measured rather than assumed, because "the bars are the same length" is
    /// a claim about what is drawn, not about the rectangles handed to the
    /// drawing code.
    private func inkedWidth(_ at: (CGFloat, CGFloat) -> NSColor?, y: CGFloat, from: CGFloat, to: CGFloat) -> CGFloat {
        let step = MicBadgeIcon.size / CGFloat(Self.scale * Int(MicBadgeIcon.size))
        var inked: CGFloat = 0
        var x = from
        while x <= to {
            if (at(x, y)?.alphaComponent ?? 0) > 0.5 { inked += step }
            x += step
        }
        return inked
    }

    /// Which of the four bars have ink, sampled at the middle of each one.
    private func inkedBars(_ image: NSImage) throws -> [Bool] {
        let (_, at) = try sampler(image)
        return MicBadgeIcon.Geometry.bars.map { bar in
            (at(bar.midX, bar.midY)?.alphaComponent ?? 0) > 0.5
        }
    }

    @Test("The badge is an 18×18 template image in every ordinary state", arguments: [
        MicBadgeIcon.Kind.level(0, online: 0), .level(2, online: 0), .level(4, online: 0),
        .offline, .disconnected, .connecting,
    ])
    func templateAndSize(kind: MicBadgeIcon.Kind) {
        let image = MicBadgeIcon.image(kind: kind)

        #expect(image.isTemplate)
        #expect(image.size == NSSize(width: 18, height: 18))
    }

    @Test("The letter's stem is always inked, and the canvas corners never are", arguments: [
        MicBadgeIcon.Kind.level(0, online: 0), .level(4, online: 0), .offline,
    ])
    func outlineIsDrawn(kind: MicBadgeIcon.Kind) throws {
        let image = MicBadgeIcon.image(kind: kind)

        let (_, at) = try sampler(image)

        #expect((at(MicBadgeIcon.Geometry.stemX, 7)?.alphaComponent ?? 0) > 0.3, "the stem should be inked")
        #expect((at(0.5, 0.5)?.alphaComponent ?? 1) < 0.1, "bottom-left corner should be clear")
        #expect((at(17.5, 17.5)?.alphaComponent ?? 1) < 0.1, "top-right corner should be clear")
        #expect((at(17.5, 0.5)?.alphaComponent ?? 1) < 0.1, "bottom-right corner should be clear")
    }

    /// The letter is one closed stroke around a single hollow — no horizontal
    /// bar across the middle, and nothing between the stem and the bars.
    @Test("At level 0 the letter is hollow from the stem to the lobes")
    func hollowAtZero() throws {
        let image = MicBadgeIcon.image(kind: .level(0, online: 0))

        let (_, at) = try sampler(image)

        // Between the stem and where the bars would start.
        #expect((at((MicBadgeIcon.Geometry.stemX + MicBadgeIcon.Geometry.barLeft) / 2, 9.4)?.alphaComponent ?? 1) < 0.1)
        // Where a waist bar would be on a letter drawn as two counters.
        #expect((at(MicBadgeIcon.Geometry.barLeft + 1, MicBadgeIcon.Geometry.waistY)?.alphaComponent ?? 1) < 0.1)
        #expect(try inkedBars(image) == [false, false, false, false])
    }

    @Test("Bars fill from the bottom, one per level", arguments: [
        (UInt8(0), [false, false, false, false]),
        (UInt8(1), [true, false, false, false]),
        (UInt8(2), [true, true, false, false]),
        (UInt8(3), [true, true, true, false]),
        (UInt8(4), [true, true, true, true]),
    ])
    func barCount(level: UInt8, expected: [Bool]) throws {
        let image = MicBadgeIcon.image(kind: .level(level, online: 0))

        #expect(try inkedBars(image) == expected)
    }

    /// The old badge clipped full-width bars to two separate counters, so the
    /// lower pair came out longer than the upper pair. These are four bars of
    /// one size, which is what a gauge looks like.
    @Test("Every bar is the same length, sampled at both ends")
    func barsAreEqualLength() throws {
        let image = MicBadgeIcon.image(kind: .level(4, online: 0))
        let bars = MicBadgeIcon.Geometry.bars

        let (_, at) = try sampler(image)

        #expect(Set(bars.map(\.width)).count == 1, "the geometry itself should give equal widths")
        let widths = bars.map { inkedWidth(at, y: $0.midY, from: bars[0].minX - 1, to: bars[0].maxX + 1) }
        for width in widths {
            #expect(abs(width - widths[0]) < 0.3, "bars came out \(widths) points wide")
            #expect(width > bars[0].width - 0.6, "a bar barely got drawn: \(widths)")
        }
    }

    @Test("Bars stay clear of the letter on both sides")
    func barsDoNotTouchTheOutline() throws {
        let image = MicBadgeIcon.image(kind: .level(4, online: 0))

        let (_, at) = try sampler(image)

        for bar in MicBadgeIcon.Geometry.bars {
            #expect((at(0.5, bar.midY)?.alphaComponent ?? 1) < 0.1, "ink left of the stem at y=\(bar.midY)")
            #expect((at(17.5, bar.midY)?.alphaComponent ?? 1) < 0.1, "ink right of the lobes at y=\(bar.midY)")
        }
        // The waist is the narrowest point of the hollow; the bars must clear it.
        #expect(MicBadgeIcon.Geometry.bars[0].maxX < MicBadgeIcon.Geometry.waistX - MicBadgeIcon.Geometry.stroke / 2)
    }

    @Test("An offline transmitter draws the letter and nothing inside it")
    func offlineHasNoBars() throws {
        let image = MicBadgeIcon.image(kind: .offline)

        let (_, at) = try sampler(image)

        #expect(try inkedBars(image) == [false, false, false, false])
        // Still visible, just dimmer than a connected one.
        let stem = try #require(at(MicBadgeIcon.Geometry.stemX, 7)?.alphaComponent)
        #expect(stem > 0.3 && stem < 0.9)
    }

    @Test("A missing receiver is struck through; a connected one is not")
    func strikeThrough() throws {
        let disconnected = MicBadgeIcon.image(kind: .disconnected)
        let connected = MicBadgeIcon.image(kind: .level(3, online: 0))

        let (_, disconnectedAt) = try sampler(disconnected)
        let (_, connectedAt) = try sampler(connected)

        // A point on the diagonal but outside the letter.
        #expect((disconnectedAt(15.5, 14.8)?.alphaComponent ?? 0) > 0.2, "no strike drawn")
        #expect((connectedAt(15.5, 14.8)?.alphaComponent ?? 1) < 0.1, "a connected receiver must not be struck through")
    }

    @Test("The last bar is red and the rest are not", arguments: [true, false])
    func lastBarIsRed(dark: Bool) throws {
        let low = MicBadgeIcon.image(kind: .level(1, online: 0), darkAppearance: dark)
        let healthy = MicBadgeIcon.image(kind: .level(4, online: 0), darkAppearance: dark)

        #expect(!low.isTemplate, "a template image is alpha only — the red would be lost")
        let bar = MicBadgeIcon.Geometry.bars[0]
        let lowInk = try #require(try sampler(low).at(bar.midX, bar.midY))
        #expect(lowInk.redComponent - lowInk.blueComponent > 0.2, "expected a red bar, got \(lowInk)")

        // Bars 2 to 4 are ordinary ink, whatever bar 1 is doing.
        let healthyAt = try sampler(healthy).at
        for other in MicBadgeIcon.Geometry.bars.dropFirst() {
            let ink = try #require(healthyAt(other.midX, other.midY))
            #expect(abs(ink.redComponent - ink.blueComponent) < 0.1, "bar at \(other.midY) should not be red, got \(ink)")
        }
        #expect(healthy.isTemplate)
    }

    @Test("One green dot per online transmitter, the second below the first", arguments: [0, 1, 2])
    func onlineDots(count: Int) throws {
        let image = MicBadgeIcon.image(kind: .level(3, online: count))

        let (_, at) = try sampler(image)

        for (index, centre) in MicBadgeIcon.Geometry.dotCentres.enumerated() {
            let ink = at(centre.x, centre.y)
            if index < count {
                let dot = try #require(ink)
                #expect(dot.greenComponent - dot.redComponent > 0.2, "dot \(index + 1) is not green: \(dot)")
            } else {
                #expect((ink?.alphaComponent ?? 0) < 0.2, "dot \(index + 1) should not be drawn for \(count) online")
            }
        }
        #expect(image.isTemplate == (count == 0), "colour and template mode are mutually exclusive")
    }

    @Test("The second dot sits directly below the first, not beside it")
    func dotsStackVertically() {
        let dots = MicBadgeIcon.Geometry.dotCentres

        #expect(dots.count == 2)
        #expect(dots[0].x == dots[1].x)
        #expect(dots[1].y < dots[0].y)
        #expect(dots[0].y - dots[1].y >= MicBadgeIcon.Geometry.dotRadius * 2, "the dots would overlap")
    }

    @Test("With colour on it, the letter still follows the menu bar")
    func colouredOutlineFollowsAppearance() throws {
        let onDark = MicBadgeIcon.image(kind: .level(1, online: 1), darkAppearance: true)
        let onLight = MicBadgeIcon.image(kind: .level(1, online: 1), darkAppearance: false)

        let dark = try #require(try sampler(onDark).at(MicBadgeIcon.Geometry.stemX, 7))
        let light = try #require(try sampler(onLight).at(MicBadgeIcon.Geometry.stemX, 7))

        #expect(dark.brightnessComponent > 0.9, "the letter should be white on a dark menu bar")
        #expect(light.brightnessComponent < 0.1, "the letter should be black on a light menu bar")
    }

    @Test("A state with no bars and no dots stays a template")
    func statesWithoutColourStayTemplates() {
        #expect(MicBadgeIcon.image(kind: .offline).isTemplate)
        #expect(MicBadgeIcon.image(kind: .disconnected).isTemplate)
        #expect(MicBadgeIcon.image(kind: .connecting).isTemplate)
        #expect(MicBadgeIcon.image(kind: .level(0, online: 0)).isTemplate)
    }

    @Test("Every state carries an accessibility description")
    func accessibility() {
        #expect(MicBadgeIcon.image(kind: .level(3, online: 1)).accessibilityDescription == "BOYA mic battery 3 of 4, 1 transmitter online")
        #expect(MicBadgeIcon.image(kind: .level(3, online: 2)).accessibilityDescription == "BOYA mic battery 3 of 4, 2 transmitters online")
        #expect(MicBadgeIcon.image(kind: .offline).accessibilityDescription == "BOYA mic offline")
        #expect(MicBadgeIcon.image(kind: .disconnected).accessibilityDescription == "BOYA receiver not connected")
        #expect(MicBadgeIcon.image(kind: .connecting).accessibilityDescription == "BOYA receiver connecting")
    }

    @Test("A level beyond four does not draw a fifth bar")
    func levelIsClamped() throws {
        #expect(try inkedBars(MicBadgeIcon.image(kind: .level(9, online: 0))) == [true, true, true, true])
    }

    @Test("The bars are stacked bottom to top, evenly, without overlapping")
    func barGeometry() {
        let bars = MicBadgeIcon.Geometry.bars

        #expect(bars.count == 4)
        #expect(Set(bars.map(\.height)).count == 1)
        for (lower, upper) in zip(bars, bars.dropFirst()) {
            #expect(lower.maxY < upper.minY, "bars must not overlap")
            #expect(abs((upper.minY - lower.maxY) - MicBadgeIcon.Geometry.barGap) < 0.001, "gaps must be equal")
        }
        // The block is centred in the hollow.
        let floor = MicBadgeIcon.Geometry.bottomY + MicBadgeIcon.Geometry.stroke / 2
        let ceiling = MicBadgeIcon.Geometry.topY - MicBadgeIcon.Geometry.stroke / 2
        let below = bars[0].minY - floor
        let above = ceiling - bars[3].maxY
        #expect(abs(below - above) < 0.001, "the block should be centred: \(below) below, \(above) above")
    }
}
