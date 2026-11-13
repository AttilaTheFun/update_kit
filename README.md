# Update Kit

`UpdateKit`: the library the apps that Applications distributes link, to
record the build each one is in the app group they share with
Applications, and to hear of their own updates (docs/Updates.md). Until
0.11.0 it was the module `ApplicationUpdates`, in AttilaTheFun/applications.

    .package(url: "https://github.com/AttilaTheFun/update_kit.git", exact: "0.11.0")

    .product(name: "UpdateKit", package: "update_kit")

    import UpdateKit

The app group it shares with Applications, and on a Mac Applications'
bundle ids, come from the app's Info.plist (`UpdateKitAppGroup`,
`UpdateKitApplicationsBundleIDs`), which the distributor's CI stamps in;
without them it does nothing. An app tells of nothing and shows no update
UI: only Applications tells of updates (0.17.0; docs/Updates.md).

It depends on [swift_sql](https://github.com/AttilaTheFun/swift_sql)'s
`SwiftSQL`. Tested on Linux; built for iOS and macOS on Linux too (Bazel
with rules_applecross: MODULE.bazel, `tools/ci/container_build.sh`).

Where there are no app groups or Darwin notifications (Linux, and Isomer's
hosts, such as its headless host for an app's Linux tests), the same API
works within one process: `AppGroupStore.appGroup` keeps the database in the
folder `UPDATEKIT_APP_GROUP_CONTAINER` names (else `$XDG_DATA_HOME/<group>`),
and `UpdateSignal` is heard by the process that posts it.

## Releasing

A release is proposed by hand, on main, and released by the owner in
Reviews, which publishes the draft and makes its `v<version>` tag:

    gh workflow run CI --ref main -f run=release -f version=0.12.0

CI runs the tests on Linux, writes their proof in format 2
(AttilaTheFun/reviews' docs/PROOF_FORMAT.md; tools/ci/proof.sh), and
proposes the draft "UpdateKit <version>" with the proof attached as
proof.zip (tools/ci/propose.sh). `-f run=verify` runs the tests and makes
the proof alone. One release a minor line: a version whose line has a
published release is refused.
