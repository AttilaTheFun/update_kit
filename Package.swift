// swift-tools-version: 6.0

// UpdateKit (the module ApplicationUpdates until 0.11.0): the library every
// app Applications distributes uses to record the build it is and hear of
// its own updates (docs/Updates.md).
// Other repositories depend on it by version (its tags), through SwiftPM or
// rules_swift_package_manager.
import PackageDescription

let package = Package(
    name: "update_kit",
    // swift_sql's own floor: an app of any of the apps' minimums takes it.
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "UpdateKit", targets: ["UpdateKit"]),
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
        .testTarget(
            name: "UpdateKitTests",
            dependencies: ["UpdateKit", .product(name: "SwiftSQL", package: "swift_sql")]),
    ],
    swiftLanguageModes: [.v6]
)
