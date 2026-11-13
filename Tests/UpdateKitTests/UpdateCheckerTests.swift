import Foundation
import Testing
import UpdateKit

/// The app's check at launch: its build written, and what Applications
/// knows of a newer one decided. Nothing is told (only Applications tells of
/// updates).
@Suite(.serialized)
final class UpdateCheckerTests {
    private let temporary = TemporaryDatabase()
    private let app = InstalledApp(bundleID: "com.example.Visor", version: "0.39.2", build: "1")

    deinit { temporary.remove() }

    private func latest(_ version: String, in store: AppGroupStore) async throws {
        try await store.setLatest([LatestBuild(bundleID: app.bundleID, version: version, build: "1",
                                               installURL: URL(string: "itms-services://?action=download-manifest&url=x"))])
    }

    @Test func nothingKnownYetWritesTheBuild() async throws {
        let store = AppGroupStore(fileURL: temporary.file)
        #expect(try await UpdateChecker(store: store, app: app).check() == .unknown)
        #expect(try await store.record(bundleID: app.bundleID)?.installedVersion == "0.39.2")
    }

    @Test func upToDate() async throws {
        let store = AppGroupStore(fileURL: temporary.file)
        try await latest("0.39.2", in: store)
        #expect(try await UpdateChecker(store: store, app: app).check() == .upToDate)
    }

    @Test func aNewerBuildIsFound() async throws {
        let store = AppGroupStore(fileURL: temporary.file)
        try await latest("0.40.1", in: store)
        let found = try await UpdateChecker(store: store, app: app).check()
        guard case .available(let update) = found else { Issue.record("no update: \(found)"); return }
        #expect(update.version == "0.40.1")
        #expect(update.installedVersion == "0.39.2")
        #expect(update.installURL?.scheme == "itms-services")
    }

    @Test func anOlderLatestIsNoUpdate() async throws {
        let store = AppGroupStore(fileURL: temporary.file)
        try await latest("0.38.9", in: store)
        #expect(try await UpdateChecker(store: store, app: app).check() == .upToDate, "a build newer than any published")
    }

    @Test func anUpdateCarriesItselfInAUserInfo() {
        let update = AvailableUpdate(bundleID: "com.example.Visor", version: "0.40.1", build: "1", installURL: URL(string: "https://server/a.zip"),
                                     installedVersion: "0.39.2", installedBuild: nil)
        let info: [AnyHashable: Any] = update.userInfo
        #expect(AvailableUpdate(userInfo: info) == update)
        #expect(AvailableUpdate(userInfo: ["build": "b1"]) == nil, "another notification's")
    }
}
