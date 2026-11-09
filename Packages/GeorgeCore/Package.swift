// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "GeorgeCore",
    platforms: [
        .iOS("26.0"),
        .macOS("26.0"),
        .watchOS("26.0"),
    ],
    products: [
        .library(name: "GeorgeCore", targets: ["GeorgeCore"]),
    ],
    dependencies: [
        .package(path: "../../Vendor/BinisoftKit"),
    ],
    targets: [
        .target(
            name: "GeorgeCore",
            dependencies: [.product(name: "BinisoftKitCore", package: "BinisoftKit")]
        ),
        .testTarget(name: "GeorgeCoreTests", dependencies: ["GeorgeCore"]),
    ],
    swiftLanguageModes: [.v5]
)
