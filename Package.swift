// swift-tools-version: 6.0

// UpdateKit (the module ApplicationUpdates until 0.11.0): the library every
// app Applications distributes uses to record the build it is and hear of
// its own updates (docs/Updates.md).
// Other repositories depend on it by version (its tags), through SwiftPM or
// rules_swift_package_manager.
import PackageDescription

let package = Package(
    name: "update_kit",
    // Observation's floor (UpdateStatus); the apps' own minimums are higher.
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "UpdateKit", targets: ["UpdateKit"]),
        // The update UI in SwiftUI: a banner and a version section. Empty
        // where there is no SwiftUI (Linux).
        .library(name: "UpdateKitUI", targets: ["UpdateKitUI"]),
    ],
    dependencies: [
        // A range, not one version: the apps pin swift_sql themselves, and
        // their pin is the one taken.
        .package(url: "https://github.com/AttilaTheFun/swift_sql.git", from: "0.35.0"),
    ],
    targets: [
        .target(
            name: "UpdateKit",
            dependencies: [.product(name: "SwiftSQL", package: "swift_sql")]),
        .target(
            name: "UpdateKitUI",
            dependencies: ["UpdateKit"]),
        .testTarget(
            name: "UpdateKitTests",
            dependencies: ["UpdateKit", .product(name: "SwiftSQL", package: "swift_sql")]),
    ],
    swiftLanguageModes: [.v6]
)
