import CoreGraphics
import Testing
@testable import BusySignCore

/// A square RGBA bitmap (sRGB, 8 bits, premultiplied alpha) drawn into a fresh context, read back by design
/// coordinates: x and y in design units from the top-left corner, as in the SVG sources.
struct DesignBitmap {
    struct Pixel {
        let red, green, blue, alpha: UInt8
    }

    private let bytes: [UInt8]
    private let bytesPerRow: Int
    private let units: CGFloat
    private let gridScale: CGFloat
    private let pixelsPerUnit: CGFloat

    /// `gridScale` is the scale about the canvas centre at which the design is drawn (the app icon's 103/120 for
    /// Apple's icon grid); `pixel(x:y:)` maps design points through it.
    init(pixels: Int, units: CGFloat, gridScale: CGFloat = 1, draw: (CGContext) -> Void) throws {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        draw(context)
        let data = try #require(context.data)
        bytesPerRow = context.bytesPerRow
        bytes = Array(UnsafeRawBufferPointer(start: data, count: bytesPerRow * pixels))
        self.units = units
        self.gridScale = gridScale
        pixelsPerUnit = CGFloat(pixels) / units
    }

    /// The pixel that covers the design point, after the grid scale about the centre.
    func pixel(x: CGFloat, y: CGFloat) -> Pixel {
        let centre = units / 2
        return canvasPixel(x: centre + (x - centre) * gridScale, y: centre + (y - centre) * gridScale)
    }

    /// The pixel that covers a canvas point: the same units from the top-left, without the grid scale. A bitmap
    /// context keeps its top row first in memory while its user space has y up, so a y measured from the top is
    /// the memory row as it is.
    func canvasPixel(x: CGFloat, y: CGFloat) -> Pixel {
        let column = Int((x * pixelsPerUnit).rounded(.down))
        let row = Int((y * pixelsPerUnit).rounded(.down))
        let offset = row * bytesPerRow + column * 4
        return Pixel(red: bytes[offset], green: bytes[offset + 1], blue: bytes[offset + 2], alpha: bytes[offset + 3])
    }
}

@Suite struct BrandArtTests {
    func icon(pixels: Int = 128) throws -> DesignBitmap {
        // 103.0 / 120 repeats BrandArt's grid scale on purpose: an independent pin, so a changed scale fails here.
        try DesignBitmap(pixels: pixels, units: 128, gridScale: 103.0 / 120) {
            BrandArt.drawAppIcon(in: $0, size: CGFloat(pixels))
        }
    }

    func glyph(attention: Bool) throws -> DesignBitmap {
        try DesignBitmap(pixels: 36, units: 18) { BrandArt.drawMenuGlyph(in: $0, size: 36, attention: attention) }
    }

    func isTeal(_ p: DesignBitmap.Pixel) -> Bool { p.alpha == 255 && p.green > p.red && p.blue > p.red }

    /// Pins the helper to CoreGraphics without the artwork: a band filled at the top of user space (y up) reads
    /// back near design y 0, so a design drawn upside down cannot pass the tests below.
    @Test func bitmapReadsTheTopOfUserSpaceAsDesignTop() throws {
        let bitmap = try DesignBitmap(pixels: 36, units: 18) { context in
            context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 27, width: 36, height: 9))
        }
        #expect(bitmap.pixel(x: 9, y: 1).alpha == 255)
        #expect(bitmap.pixel(x: 9, y: 17).alpha == 0)
    }

    @Test func iconIsTransparentOutsideTheTile() throws {
        #expect(try icon().pixel(x: 2, y: 2).alpha == 0)
    }

    /// The tile sits on Apple's icon grid, 12.5…115.5 of 128 units (824 of 1024 px), so canvas x 8, inside the
    /// SVG's own tile (4…124), is now outside it. Canvas points: a design point keeps its side of the tile under
    /// the grid scale.
    @Test func iconTileFollowsTheIconGrid() throws {
        let bitmap = try icon()
        #expect(bitmap.canvasPixel(x: 8, y: 64).alpha == 0)
        #expect(isTeal(bitmap.canvasPixel(x: 14, y: 64)))
        #expect(isTeal(bitmap.canvasPixel(x: 114, y: 64)))
        #expect(bitmap.canvasPixel(x: 116, y: 64).alpha == 0)
    }

    @Test func iconLeverIsGold() throws {
        let p = try icon().pixel(x: 50, y: 34)
        #expect(p.alpha == 255 && p.red > 200 && p.green > 150 && p.blue < 120)
    }

    @Test func iconHangerIsWhite() throws {
        let p = try icon().pixel(x: 64, y: 105)
        #expect(p.alpha == 255 && p.red > 240 && p.green > 240 && p.blue > 240)
    }

    @Test func iconTileIsTeal() throws {
        #expect(isTeal(try icon().pixel(x: 100, y: 110)))
    }

    /// The ring between the gold knob (r 6.5) and the cut (r 10.5) shows the tile, not the hanger.
    @Test func iconHoleShowsTheTile() throws {
        #expect(isTeal(try icon().pixel(x: 64, y: 42)))
    }

    /// Lighter green (#1fb38a) at the top-left, darker teal (#0f7d8c) at the bottom-right.
    @Test func iconGradientRunsFromTopLeftToBottomRight() throws {
        let bitmap = try icon()
        let topLeft = bitmap.pixel(x: 20, y: 20), bottomRight = bitmap.pixel(x: 108, y: 108)
        #expect(isTeal(topLeft) && isTeal(bottomRight))
        #expect(Int(topLeft.green) - Int(bottomRight.green) > 30)
    }

    @Test func iconScalesWithSize() throws {
        let p = try icon(pixels: 1024).pixel(x: 50, y: 34)
        #expect(p.alpha == 255 && p.red > 200 && p.green > 150 && p.blue < 120)
    }

    @Test func glyphPillIsOpaqueBlack() throws {
        let p = try glyph(attention: false).pixel(x: 9.5, y: 12)
        #expect(p.alpha == 255 && p.red == 0 && p.green == 0 && p.blue == 0)
    }

    @Test func glyphIsTransparentBelowTheLever() throws {
        #expect(try glyph(attention: false).pixel(x: 3, y: 15).alpha == 0)
    }

    @Test func glyphDotOnlyWithAttention() throws {
        #expect(try glyph(attention: false).pixel(x: 15.5, y: 2.5).alpha == 0)
        #expect(try glyph(attention: true).pixel(x: 15.5, y: 2.5).alpha == 255)
    }

    /// The badge stands apart from the outline: a circle of r 3.2 is cleared before the r 2 dot, so the outline's
    /// right edge at about 2.6 from the dot's centre is gone with attention.
    @Test func glyphBadgeClearsTheOutlineAroundTheDot() throws {
        #expect(try glyph(attention: false).pixel(x: 13.25, y: 3.75).alpha == 255)
        #expect(try glyph(attention: true).pixel(x: 13.25, y: 3.75).alpha == 0)
    }

    /// The knock-out clears the glyph only: whatever the context held before stays, so a drawing handler that
    /// draws straight into its destination cannot punch a hole into it.
    @Test func glyphBadgeKeepsWhatIsUnderTheGlyph() throws {
        let bitmap = try DesignBitmap(pixels: 36, units: 18) { context in
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 36, height: 36))
            BrandArt.drawMenuGlyph(in: context, size: 36, attention: true)
        }
        let p = bitmap.pixel(x: 13.25, y: 3.75)
        #expect(p.alpha == 255 && p.red == 255 && p.green == 255 && p.blue == 255)
    }
}
