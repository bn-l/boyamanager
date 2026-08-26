import AppKit
import Testing
@testable import BoyaManager

@Suite("Menu bar icon")
struct MicBadgeIconTests {
    /// Rasterizes the badge and samples it in the icon's own coordinate space
    /// (0…18, origin bottom-left) so the tests read like the geometry does and
    /// hold regardless of backing scale.
    private func sampler(_ image: NSImage) throws -> (rep: NSBitmapImageRep, at: (CGFloat, CGFloat) -> NSColor?) {
        let tiff = try #require(image.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        let size = MicBadgeIcon.size
        let at: (CGFloat, CGFloat) -> NSColor? = { x, y in
            let px = min(rep.pixelsWide - 1, max(0, Int(x / size * CGFloat(rep.pixelsWide))))
            let py = min(rep.pixelsHigh - 1, max(0, Int((size - y) / size * CGFloat(rep.pixelsHigh))))
            return rep.colorAt(x: px, y: py)?.usingColorSpace(.sRGB)
        }
        return (rep, at)
    }

    /// Which of the four bars have ink, sampled at the middle of each one.
    private func inkedBars(_ image: NSImage) throws -> [Bool] {
        let (_, at) = try sampler(image)
        return MicBadgeIcon.Geometry.bars.map { bar in
            (at(9, bar.midY)?.alphaComponent ?? 0) > 0.5
        }
    }

    @Test("The badge is an 18×18 template image in every ordinary state", arguments: [
        MicBadgeIcon.Kind.level(0), .level(2), .level(4), .offline, .disconnected, .connecting,
    ])
    func templateAndSize(kind: MicBadgeIcon.Kind) {
        let image = MicBadgeIcon.image(kind: kind)

        #expect(image.isTemplate)
        #expect(image.size == NSSize(width: 18, height: 18))
    }

    @Test("The letter's stem is always inked, and the canvas corners never are", arguments: [
        MicBadgeIcon.Kind.level(0), .level(4), .offline,
    ])
    func outlineIsDrawn(kind: MicBadgeIcon.Kind) throws {
        let image = MicBadgeIcon.image(kind: kind)

        let (_, at) = try sampler(image)

        #expect((at(2.8, 9)?.alphaComponent ?? 0) > 0.3, "the stem should be inked")
        #expect((at(0.5, 0.5)?.alphaComponent ?? 1) < 0.1, "bottom-left corner should be clear")
        #expect((at(17.5, 17.5)?.alphaComponent ?? 1) < 0.1, "top-right corner should be clear")
        #expect((at(17.5, 0.5)?.alphaComponent ?? 1) < 0.1, "bottom-right corner should be clear")
    }

    @Test("At level 0 the letter is hollow — both counters are empty")
    func hollowAtZero() throws {
        let image = MicBadgeIcon.image(kind: .level(0))

        let (_, at) = try sampler(image)

        #expect((at(MicBadgeIcon.Geometry.lowerCounter.midX, MicBadgeIcon.Geometry.lowerCounter.midY)?.alphaComponent ?? 1) < 0.1)
        #expect((at(MicBadgeIcon.Geometry.upperCounter.midX, MicBadgeIcon.Geometry.upperCounter.midY)?.alphaComponent ?? 1) < 0.1)
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
        let image = MicBadgeIcon.image(kind: .level(level))

        #expect(try inkedBars(image) == expected)
    }

    @Test("Bars stay inside the letter — they never bleed past the outline")
    func barsAreClipped() throws {
        let image = MicBadgeIcon.image(kind: .level(4))

        let (_, at) = try sampler(image)

        // The bars are drawn as full-width rectangles and rely on the counters
        // to clip them; a broken clip shows up immediately outside the letter.
        for bar in MicBadgeIcon.Geometry.bars {
            #expect((at(0.5, bar.midY)?.alphaComponent ?? 1) < 0.1, "ink left of the stem at y=\(bar.midY)")
            #expect((at(17.5, bar.midY)?.alphaComponent ?? 1) < 0.1, "ink right of the lobes at y=\(bar.midY)")
        }
    }

    @Test("An offline transmitter draws the letter and nothing inside it")
    func offlineHasNoBars() throws {
        let image = MicBadgeIcon.image(kind: .offline)

        let (_, at) = try sampler(image)

        #expect(try inkedBars(image) == [false, false, false, false])
        // Still visible, just dimmer than a connected one.
        let stem = try #require(at(2.8, 9)?.alphaComponent)
        #expect(stem > 0.3 && stem < 0.9)
    }

    @Test("A missing receiver is struck through; a connected one is not")
    func strikeThrough() throws {
        let disconnected = MicBadgeIcon.image(kind: .disconnected)
        let connected = MicBadgeIcon.image(kind: .level(3))

        let (_, disconnectedAt) = try sampler(disconnected)
        let (_, connectedAt) = try sampler(connected)

        // A point on the diagonal but outside the letter.
        #expect((disconnectedAt(15, 14.2)?.alphaComponent ?? 0) > 0.2, "no strike drawn")
        #expect((connectedAt(15, 14.2)?.alphaComponent ?? 1) < 0.1, "a connected receiver must not be struck through")
    }

    @Test("Low battery drops template mode and paints the bars red, on both appearances", arguments: [true, false])
    func lowBatteryIsRed(dark: Bool) throws {
        let image = MicBadgeIcon.image(kind: .level(1), lowBattery: true, darkAppearance: dark)

        #expect(!image.isTemplate, "a template image is alpha only — the red would be lost")
        let (_, at) = try sampler(image)
        let bar = try #require(at(9, MicBadgeIcon.Geometry.bars[0].midY))
        #expect(bar.redComponent > 0.5)
        #expect(bar.redComponent - bar.blueComponent > 0.2, "expected red bars, got \(bar)")
    }

    @Test("With low battery the letter itself follows the menu bar, not the bars")
    func lowBatteryOutlineFollowsAppearance() throws {
        let onDark = MicBadgeIcon.image(kind: .level(1), lowBattery: true, darkAppearance: true)
        let onLight = MicBadgeIcon.image(kind: .level(1), lowBattery: true, darkAppearance: false)

        let dark = try #require(try sampler(onDark).at(2.8, 9))
        let light = try #require(try sampler(onLight).at(2.8, 9))

        #expect(dark.brightnessComponent > 0.9, "the letter should be white on a dark menu bar")
        #expect(light.brightnessComponent < 0.1, "the letter should be black on a light menu bar")
    }

    @Test("A healthy battery is never coloured, even when asked for a specific appearance")
    func healthyBatteryStaysTemplate() throws {
        let image = MicBadgeIcon.image(kind: .level(4), lowBattery: false, darkAppearance: false)

        #expect(image.isTemplate)
    }

    @Test("A low flag on a state with no bars stays a template — there is nothing to colour")
    func lowFlagWithoutBars() {
        #expect(MicBadgeIcon.image(kind: .offline, lowBattery: true).isTemplate)
        #expect(MicBadgeIcon.image(kind: .disconnected, lowBattery: true).isTemplate)
    }

    @Test("Every state carries an accessibility description")
    func accessibility() {
        #expect(MicBadgeIcon.image(kind: .level(3)).accessibilityDescription == "BOYA mic battery 3 of 4")
        #expect(MicBadgeIcon.image(kind: .offline).accessibilityDescription == "BOYA mic offline")
        #expect(MicBadgeIcon.image(kind: .disconnected).accessibilityDescription == "BOYA receiver not connected")
        #expect(MicBadgeIcon.image(kind: .connecting).accessibilityDescription == "BOYA receiver connecting")
    }

    @Test("A level beyond four does not draw a fifth bar")
    func levelIsClamped() throws {
        #expect(try inkedBars(MicBadgeIcon.image(kind: .level(9))) == [true, true, true, true])
    }

    @Test("The bars sit inside the counters, in order, without overlapping")
    func barGeometry() {
        let bars = MicBadgeIcon.Geometry.bars

        #expect(bars.count == 4)
        for (lower, upper) in zip(bars, bars.dropFirst()) {
            #expect(lower.maxY <= upper.minY, "bars must not overlap")
        }
        #expect(MicBadgeIcon.Geometry.lowerCounter.contains(CGPoint(x: 9, y: bars[0].midY)))
        #expect(MicBadgeIcon.Geometry.lowerCounter.contains(CGPoint(x: 9, y: bars[1].midY)))
        #expect(MicBadgeIcon.Geometry.upperCounter.contains(CGPoint(x: 9, y: bars[2].midY)))
        #expect(MicBadgeIcon.Geometry.upperCounter.contains(CGPoint(x: 9, y: bars[3].midY)))
    }
}
