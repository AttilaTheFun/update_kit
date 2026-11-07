# Update Kit

`UpdateKit`: the library the apps that Applications distributes link, to
record the build each one is in the app group they share with
Applications, and to hear of their own updates (docs/Updates.md). Until
0.11.0 it was the module `ApplicationUpdates`, in AttilaTheFun/applications.

    .package(url: "https://github.com/AttilaTheFun/update_kit.git", exact: "0.11.0")

    .product(name: "UpdateKit", package: "update_kit")

    import UpdateKit

It depends on [swift_sql](https://github.com/AttilaTheFun/swift_sql)'s
`SwiftSQL`. Tested on Linux and on Apple's platforms.
