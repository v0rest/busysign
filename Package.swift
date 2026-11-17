// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BusySign",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "BusySign", targets: ["BusySign"]),
        .library(name: "BusySignCore", targets: ["BusySignCore"]),
    ],
    targets: [
        .target(name: "BusySignCore"),
        .executableTarget(name: "BusySign", dependencies: ["BusySignCore"]),
        // Renders Resources/AppIcon.icns from BrandArt; run by hand (`swift run make-icon`), not shipped.
        .executableTarget(name: "make-icon", dependencies: ["BusySignCore"]),
        .testTarget(name: "BusySignCoreTests", dependencies: ["BusySignCore"]),
    ],
    swiftLanguageModes: [.v6]
)
