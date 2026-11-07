# Update Kit

`ApplicationUpdates`: the library the apps that Applications distributes
link, to record the build each one is in the app group they share with
Applications, and to hear of their own updates (docs/Updates.md).

    .package(url: "https://github.com/AttilaTheFun/update_kit.git", exact: "0.10.45")

    .product(name: "ApplicationUpdates", package: "update_kit")

It depends on [swift_sql](https://github.com/AttilaTheFun/swift_sql)'s
`SwiftSQL`. Tested on Linux and on Apple's platforms.
