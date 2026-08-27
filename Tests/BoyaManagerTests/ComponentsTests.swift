import AppKit
@testable import BoyaManager
import SwiftUI
import Testing

@Suite("Popover components")
@MainActor
struct ComponentsTests {
    /// The darkest pixel in each bar's column, rendered over white.
    ///
    /// Over white because the difference that matters is what the eye sees: two
    /// tints can be the same colour at different alphas, which reads as two
    /// different greys and compares equal. Darkest-in-column rather than a
    /// point sample because the assertion is about the ink, not about where
    /// SwiftUI chose to put the gauge inside its frame.
    private func barInk(level: UInt8, tint: Color) throws -> [CGFloat] {
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
            var darkest: CGFloat = 1
            for x in from...min(to, image.width - 1) {
                for y in 0..<image.height {
                    let brightness = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)?.brightnessComponent ?? 1
                    darkest = min(darkest, brightness)
                }
            }
            return darkest
        }
    }

    /// The signal gauge was drawn in `.secondary` — a mid grey — beside unlit
    /// bars and a vivid green battery gauge. It was on screen the whole time
    /// and read as empty at full strength.
    @Test("A lit signal bar is plainly different from an unlit one")
    func litSignalBarsAreVisible() throws {
        let ink = try barInk(level: 2, tint: LevelBars.signal)

        #expect(
            ink[3] - ink[0] > 0.4,
            "lit bars at \(ink[0]) beside unlit ones at \(ink[3]) are not a gauge anyone can read"
        )
    }

    /// The unlit bars are still drawn — that is what keeps the gauge from
    /// changing width as the level moves — so "different from unlit" has to
    /// mean different from something that is actually there.
    @Test("Unlit bars are drawn rather than left out")
    func unlitBarsAreDrawn() throws {
        let ink = try barInk(level: 0, tint: LevelBars.signal)

        for (index, bar) in ink.enumerated() {
            #expect(bar < 0.97, "unlit bar \(index + 1) at \(bar) is not distinguishable from the background")
        }
    }
}
