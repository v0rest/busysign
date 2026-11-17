import CoreGraphics

/// The BusySign artwork, drawn with CoreGraphics alone so the app, `make-icon` and the tests share one source:
/// the app icon (`Resources/AppIcon.svg`, a 128-unit design) and the menu-bar glyph (an 18-unit template design).
/// Each function draws into the square from the origin to `size` in the context's current user space (y up) and
/// leaves the context's state as it found it. The shape numbers below are the SVG's, in its paint order.
public enum BrandArt {
    /// The SVG's tile fills 120 of its 128 units; Apple's macOS icon grid puts the tile at 824 of 1024 px. The whole
    /// design is drawn at this scale about its centre, so the tile spans 12.5…115.5 units.
    private static let appIconGridScale: CGFloat = 103.0 / 120

    /// The teal rounded tile with a white "do not disturb" hanger on a gold lever handle, on Apple's icon grid;
    /// transparent outside the tile.
    public static func drawAppIcon(in context: CGContext, size: CGFloat) {
        context.saveGState()
        defer { context.restoreGState() }
        enterDesign(context, size: size, units: 128)
        context.translateBy(x: 64, y: 64)
        context.scaleBy(x: appIconGridScale, y: appIconGridScale)
        context.translateBy(x: -64, y: -64)

        // The tile: a linear gradient across its bounds, from the top-left corner to the bottom-right one.
        let colors = [color(0x1FB38A), color(0x0F7D8C)] as CFArray
        if let space = CGColorSpace(name: CGColorSpace.sRGB),
           let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) {
            context.saveGState()
            context.addPath(roundedRect(x: 4, y: 4, width: 120, height: 120, radius: 28))
            context.clip()
            context.drawLinearGradient(gradient, start: CGPoint(x: 4, y: 4), end: CGPoint(x: 124, y: 124),
                                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            context.restoreGState()
        }

        // The hanger, with the hole it hangs by cut out so the tile shows through around the handle.
        let hanger = CGMutablePath()
        hanger.addPath(roundedRect(x: 40, y: 14, width: 48, height: 100, radius: 10))
        hanger.addEllipse(in: circle(x: 64, y: 34, radius: 10.5))
        context.addPath(hanger)
        context.setFillColor(color(0xFFFFFF))
        context.fillPath(using: .evenOdd)

        // Two rules framing the sign.
        context.setStrokeColor(color(0xE3E8EB))
        context.setLineWidth(2)
        context.strokeLineSegments(between: [CGPoint(x: 46, y: 58), CGPoint(x: 82, y: 58),
                                             CGPoint(x: 46, y: 96), CGPoint(x: 82, y: 96)])

        // The sign: a teal pill with two white dots.
        fill(context, roundedRect(x: 46, y: 67, width: 36, height: 20, radius: 10), color(0x0F7D8C))
        fill(context, CGPath(ellipseIn: circle(x: 55, y: 77, radius: 3.5), transform: nil), color(0xFFFFFF))
        fill(context, CGPath(ellipseIn: circle(x: 73, y: 77, radius: 3.5), transform: nil), color(0xFFFFFF))

        // The lever handle: bar, knob and its centre.
        fill(context, roundedRect(x: 20, y: 30, width: 44, height: 8, radius: 4), color(0xF5C04A))
        fill(context, CGPath(ellipseIn: circle(x: 64, y: 34, radius: 6.5), transform: nil), color(0xF5C04A))
        fill(context, CGPath(ellipseIn: circle(x: 64, y: 34, radius: 2.5), transform: nil), color(0xD99A1E))
    }

    /// The hanger on its handle in opaque black on transparent, for a template image; `attention` adds a badge at
    /// the top-right corner that stands apart from the outline.
    public static func drawMenuGlyph(in context: CGContext, size: CGFloat, attention: Bool) {
        context.saveGState()
        defer { context.restoreGState() }
        enterDesign(context, size: size, units: 18)
        // The glyph is composed in a layer of its own, so the badge's knock-out clears the glyph only and never
        // what the context already holds (an image's drawing handler may draw straight into its destination).
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        defer { context.endTransparencyLayer() }
        let black = color(0x000000)
        context.setStrokeColor(black)

        // The hanger outline and the ring of its hole.
        context.addPath(roundedRect(x: 5.5, y: 1.5, width: 8, height: 15, radius: 2))
        context.setLineWidth(1.4)
        context.strokePath()
        context.addEllipse(in: circle(x: 9.5, y: 5, radius: 1.8))
        context.setLineWidth(1.1)
        context.strokePath()

        // The lever bar, the knob and the sign.
        fill(context, roundedRect(x: 1, y: 4.3, width: 8.5, height: 1.4, radius: 0.7), black)
        fill(context, CGPath(ellipseIn: circle(x: 9.5, y: 5, radius: 1), transform: nil), black)
        fill(context, roundedRect(x: 6.7, y: 9.6, width: 5.6, height: 3.4, radius: 1.7), black)

        if attention {
            // The badge: a circle cleared through the outline's corner, then the dot inside it.
            context.setBlendMode(.clear)
            fill(context, CGPath(ellipseIn: circle(x: 15.5, y: 2.5, radius: 3.2), transform: nil), black)
            context.setBlendMode(.normal)
            fill(context, CGPath(ellipseIn: circle(x: 15.5, y: 2.5, radius: 2), transform: nil), black)
        }
    }

    /// Maps the design's units, top-left origin and y down, onto the square of `size` with y up.
    private static func enterDesign(_ context: CGContext, size: CGFloat, units: CGFloat) {
        context.translateBy(x: 0, y: size)
        context.scaleBy(x: size / units, y: -size / units)
    }

    /// An SVG `rect` with `rx`: the radius is capped at half the shorter side, as SVG does and CoreGraphics
    /// requires.
    private static func roundedRect(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat,
                                    radius: CGFloat) -> CGPath {
        let r = min(radius, width / 2, height / 2)
        return CGPath(roundedRect: CGRect(x: x, y: y, width: width, height: height),
                      cornerWidth: r, cornerHeight: r, transform: nil)
    }

    private static func circle(x: CGFloat, y: CGFloat, radius: CGFloat) -> CGRect {
        CGRect(x: x - radius, y: y - radius, width: 2 * radius, height: 2 * radius)
    }

    private static func fill(_ context: CGContext, _ path: CGPath, _ color: CGColor) {
        context.addPath(path)
        context.setFillColor(color)
        context.fillPath()
    }

    /// An opaque sRGB colour from a `#rrggbb` value.
    private static func color(_ hex: UInt32) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
