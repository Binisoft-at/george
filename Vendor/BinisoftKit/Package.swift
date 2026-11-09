// swift-tools-version: 6.0
import PackageDescription

// BinisoftKit – shared building blocks for every Binisoft app.
//
// It is copied into each app as Vendor/BinisoftKit by the handbook's tools/sync.sh.
// Never edit it inside an app: change it in the handbook, tag a version, sync.
//
// - BinisoftKitCore: Foundation only (tour engine, log buffer, sync status text, soft delete,
//   sort order, identifiers, CSV, import plans, AI import prompt). Tested on Linux.
// - BinisoftKit: SwiftUI / SwiftData / CloudKit / TipKit (tour coach, log screen, SyncMonitor,
//   Settings sections, theme, toasts with Undo, create sheet). Apple platforms only, so it is
//   left out when the manifest is evaluated on Linux.

var products: [Product] = [
    .library(name: "BinisoftKitCore", targets: ["BinisoftKitCore"]),
]

var targets: [Target] = [
    .target(name: "BinisoftKitCore"),
    .testTarget(name: "BinisoftKitCoreTests", dependencies: ["BinisoftKitCore"]),
]

#if !os(Linux)
products.append(.library(name: "BinisoftKit", targets: ["BinisoftKit"]))
targets.append(.target(name: "BinisoftKit", dependencies: ["BinisoftKitCore"]))
#endif

let package = Package(
    name: "BinisoftKit",
    platforms: [.iOS("26.0"), .macOS("26.0"), .watchOS("26.0")],
    products: products,
    targets: targets,
    swiftLanguageModes: [.v5]
)
