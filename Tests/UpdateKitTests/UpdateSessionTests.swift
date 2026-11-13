import Foundation
import Testing
import UpdateKit

/// What AppUpdates sets going, with a fake system
/// (UpdateSession): the check, how an update installs (the update handler as
/// it is when asked, else the platform's way), and the offers' go ahead.
/// Portable: these run on Linux, where Apple's notifications aren't.
@MainActor
@Suite(.serialized)
final class UpdateSessionTests {
    private let temporary = TemporaryDatabase()
    private let visor = "com.example.Visor"
    private var registered: UpdateHandler?
    private var handled: [String] = []

    deinit { temporary.remove() }

    private func session(platform: UpdatePlatform = .macOS, system: FakeSystem = FakeSystem(),
                         running version: String = "0.39.2") -> UpdateSession {
        let store = AppGroupStore(fileURL: temporary.file, now: { Date(timeIntervalSince1970: 1_000) })
        return UpdateSession(store: store, app: InstalledApp(bundleID: visor, version: version, build: "1"),
                             signal: UpdateSignal(appGroup: "group.example." + UUID().uuidString), system: system,
                             platform: platform, handler: { [weak self] in self?.registered },
                             now: { Date(timeIntervalSince1970: 50) })
    }

    private func newer(_ session: UpdateSession) async throws {
        try await session.store.setLatest([LatestBuild(bundleID: visor, version: "0.40.1", build: "1",
                                                       installURL: URL(string: "https://example.com/visor.zip"))])
    }

    private func handler() -> UpdateHandler {
        { [weak self] update in await MainActor.run { self?.handled.append(update.version) } }
    }

    @Test func aCheckWritesTheBuildAndFindsANewerOne() async throws {
        let session = session()
        try await newer(session)
        let found = try await session.check()
        guard case .available(let update) = found else { Issue.record("no update found: \(found)"); return }
        #expect(update.version == "0.40.1")
        #expect(try await session.store.record(bundleID: visor)?.installedVersion == "0.39.2")
    }

    @Test func withoutAHandlerAMacAsksApplicationsAndQuits() async throws {
        let system = FakeSystem()
        let session = session(system: system)
        try await newer(session)
        guard case .available(let update) = try await session.check() else { Issue.record("no update"); return }
        #expect(try await session.install(update) == .askedApplications)
        #expect(await system.events == ["changed", "open Applications", "terminate"])
        #expect(try await session.store.installRequests().map(\.version) == ["0.40.1"])
    }

    @Test func anIPhoneOpensTheInstallLink() async throws {
        let system = FakeSystem()
        let session = session(platform: .iOS, system: system)
        try await newer(session)
        guard case .available(let update) = try await session.check() else { Issue.record("no update"); return }
        #expect(try await session.install(update) == .openedInstallLink)
        #expect(await system.events == ["open https://example.com/visor.zip"])
    }

    @Test func aHandlerRegisteredAfterStartIsUsed() async throws {
        let system = FakeSystem()
        let session = session(system: system)
        try await newer(session)
        guard case .available(let update) = try await session.check() else { Issue.record("no update"); return }
        registered = handler()
        #expect(try await session.install(update) == .handled)
        #expect(handled == ["0.40.1"])
        #expect(await system.events.isEmpty, "the handler's way: Applications isn't asked")
    }

    @Test func throughApplicationsIgnoresTheHandler() async throws {
        let system = FakeSystem()
        let session = session(system: system)
        try await newer(session)
        guard case .available(let update) = try await session.check() else { Issue.record("no update"); return }
        registered = handler()
        #expect(try await session.installThroughApplications(update) == .askedApplications)
        #expect(handled.isEmpty)
        #expect(await system.events == ["changed", "open Applications", "terminate"])
    }

    @Test func goAheadUsesTheHandlerAsItIsThen() async throws {
        let system = FakeSystem()
        let session = session(system: system)
        try await newer(session)
        registered = handler()
        _ = try await session.store.makeOffer(bundleID: visor, version: "0.40.1", build: "1", offeredBy: "com.example.Applications")
        let watch = await session.answerOffers()
        defer { watch.cancel() }
        #expect(handled == ["0.40.1"], "no auto-update handler: go ahead, with the update handler registered")
        #expect(await system.events.contains("open Applications") == false)
    }

    @Test func goAheadWithoutAHandlerAsksApplications() async throws {
        let system = FakeSystem()
        let session = session(system: system)
        try await newer(session)
        _ = try await session.store.makeOffer(bundleID: visor, version: "0.40.1", build: "1", offeredBy: "com.example.Applications")
        let watch = await session.answerOffers()
        defer { watch.cancel() }
        #expect(await system.events.contains("open Applications"))
        #expect(await system.events.last == "terminate")
    }
}
