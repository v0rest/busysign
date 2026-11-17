import BusySignCore
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Renders the app icon from `BrandArt` into `<icns-dir>/AppIcon.icns` and, given a preview directory, writes PNG
// previews of the icon and the menu-bar glyph there.
//
// Usage: swift run make-icon <icns-dir> [<preview-dir>]

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// A square sRGB bitmap of `pixels` drawn by `draw`, which gets the context and the side in pixels.
func render(pixels: Int, _ draw: (CGContext, CGFloat) -> Void) throws -> CGImage {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw Failure("cannot create a \(pixels)×\(pixels) bitmap") }
    draw(context, CGFloat(pixels))
    guard let image = context.makeImage() else { throw Failure("cannot read back the \(pixels)×\(pixels) bitmap") }
    return image
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw Failure("cannot create \(url.path)") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw Failure("cannot write \(url.path)") }
}

func icon(pixels: Int) throws -> CGImage {
    try render(pixels: pixels) { BrandArt.drawAppIcon(in: $0, size: $1) }
}

/// Builds `AppIcon.iconset` next to the icns (replacing one left over from an interrupted run), converts it with
/// `iconutil` and removes it again, whether or not that worked.
func writeIcns(in directory: URL) throws {
    let files = FileManager.default
    try files.createDirectory(at: directory, withIntermediateDirectories: true)
    let iconset = directory.appendingPathComponent("AppIcon.iconset")
    let icns = directory.appendingPathComponent("AppIcon.icns")
    if files.fileExists(atPath: iconset.path) { try files.removeItem(at: iconset) }
    try files.createDirectory(at: iconset, withIntermediateDirectories: false)
    defer { try? files.removeItem(at: iconset) }

    for points in [16, 32, 128, 256, 512] {
        try writePNG(icon(pixels: points), to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
        try writePNG(icon(pixels: points * 2), to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
    }

    let iconutil = Process()
    iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    iconutil.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
    try iconutil.run()
    iconutil.waitUntilExit()
    guard iconutil.terminationStatus == 0 else {
        throw Failure("iconutil exited with status \(iconutil.terminationStatus)")
    }
    print("wrote \(icns.path)")
}

func writePreviews(in directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let previews: [(name: String, image: CGImage)] = [
        ("preview-icon-1024.png", try icon(pixels: 1024)),
        ("preview-glyph-36.png", try render(pixels: 36) { BrandArt.drawMenuGlyph(in: $0, size: $1, attention: false) }),
        ("preview-glyph-attention-36.png",
         try render(pixels: 36) { BrandArt.drawMenuGlyph(in: $0, size: $1, attention: true) }),
    ]
    for preview in previews {
        let url = directory.appendingPathComponent(preview.name)
        try writePNG(preview.image, to: url)
        print("wrote \(url.path)")
    }
}

let arguments = CommandLine.arguments.dropFirst()
guard (1...2).contains(arguments.count) else {
    FileHandle.standardError.write(Data("usage: make-icon <icns-dir> [<preview-dir>]\n".utf8))
    exit(2)
}
do {
    try writeIcns(in: URL(fileURLWithPath: arguments[arguments.startIndex]))
    if arguments.count == 2 {
        try writePreviews(in: URL(fileURLWithPath: arguments[arguments.startIndex + 1]))
    }
} catch {
    let message = (error as? Failure)?.description ?? error.localizedDescription
    FileHandle.standardError.write(Data("make-icon: error: \(message)\n".utf8))
    exit(1)
}
