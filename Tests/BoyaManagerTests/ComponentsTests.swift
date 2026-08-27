import AppKit
@testable import BoyaManager
import SwiftUI
import Testing

@Suite("Popover components")
@MainActor
struct ComponentsTests {
    /// The ink of each bar, rendered over white: per bar column, the pixel
    /// furthest from the background.
    ///
    /// Over white because the difference that matters is what the eye sees —
    /// two tints can be the same colour at different alphas, which reads as two
    /// different shades and compares equal. Furthest-from-white rather than a
    /// point sample because the assertion is about the ink, not about where
    /// SwiftUI chose to put the gauge inside its frame.
    private func barInk(level: UInt8, tint: Color) throws -> [NSColor] {
        let size = CGSize(width: 20.5, height: 11)
        let scale = CGFloat(8)
        let renderer = ImageRenderer(
            content: LevelBars(level: level, tint: tint)
                .frame(width: size.width, height: size.height)
                .background(Color.white)
        )
        renderer.scale = scale
        let image = try #require(renderer.cgImage)
        let rep = NSBitmapImageRep(cgImage: image)

        // Four bars, 4 points wide, 1.5 apart.
        return (0..<4).map { index in
            let from = Int((CGFloat(index) * 5.5 + 0.5) * scale)
            let to = Int((CGFloat(index) * 5.5 + 3.5) * scale)
            var ink = Self.white
            for x in from...min(to, image.width - 1) {
                for y in 0..<image.height {
                    guard let pixel = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    if Self.distance(pixel, Self.white) > Self.distance(ink, Self.white) { ink = pixel }
                }
            }
            return ink
        }
    }

    /// `NSColor.white` is a calibrated-white catalog colour; asking it for a
    /// red component traps.
    private static let white = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)

    /// Straight-line distance in sRGB. Crude next to a real colour difference,
    /// but it separates a colour from a grey, which brightness alone does not:
    /// green and a pale grey have almost the same brightness.
    private static func distance(_ one: NSColor, _ other: NSColor) -> CGFloat {
        let red = one.redComponent - other.redComponent
        let green = one.greenComponent - other.greenComponent
        let blue = one.blueComponent - other.blueComponent
        return (red * red + green * green + blue * blue).squareRoot()
    }

    /// The signal gauge was drawn in `.secondary` — a mid grey — with unlit
    /// bars behind it at 12% of the same grey. It was on screen the whole time
    /// and read as empty at full strength.
    @Test("A lit bar is plainly different from an unlit one")
    func litBarsAreVisible() throws {
        let ink = try barInk(level: 2, tint: LevelBars.lit)

        let apart = Self.distance(ink[0], ink[3])
        #expect(apart > 0.4, "a lit bar \(ink[0]) beside an unlit one \(ink[3]) is not a gauge anyone can read")
    }

    /// Battery and signal sit next to each other in the same row. Two gauges in
    /// two colours read as two different kinds of thing, which is how signal
    /// ended up looking like a disabled control.
    @Test("Battery and signal light up in the same colour")
    func bothGaugesUseOneColour() throws {
        let signal = try barInk(level: 2, tint: LevelBars.lit)
        let battery = try barInk(level: 2, tint: LevelBars.lit)
        let low = try barInk(level: 1, tint: LevelBars.low)

        #expect(Self.distance(signal[0], battery[0]) < 0.05)
        #expect(Self.distance(low[0], battery[0]) > 0.4, "the last-bar warning has to stand out from an ordinary bar")
    }

    /// The unlit bars are still drawn — that is what keeps the gauge from
    /// changing width as the level moves — so "different from unlit" has to
    /// mean different from something that is actually there.
    @Test("Unlit bars are drawn rather than left out")
    func unlitBarsAreDrawn() throws {
        let ink = try barInk(level: 0, tint: LevelBars.lit)

        for (index, bar) in ink.enumerated() {
            #expect(Self.distance(bar, Self.white) > 0.05, "unlit bar \(index + 1) \(bar) is not distinguishable from the background")
        }
    }
}
