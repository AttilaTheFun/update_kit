import UpdateKit
import Foundation
import SwiftSQL
import XCTest

/// Updating automatically on a Mac (docs/Updates.md): the toggle and the
/// offers in the shared database, and an app answering them.
@MainActor
final class AutoUpdateTests: XCTestCase {
    private let temporary = TemporaryDatabase()
    private let visor = "com.example.Visor"

    override func tearDown() {
        temporary.remove()
        super.tearDown()
    }

    private func store(at time: TimeInterval = 1_000) -> AppGroupStore {
        AppGroupStore(fileURL: temporary.file, now: { Date(timeIntervalSince1970: time) })
    }

    private func responder(_ store: AppGroupStore, running version: String = "0.39.2", system: FakeSystem,
                           handler: AutoUpdateHandler? = nil, installHook: AutoUpdateInstaller? = nil) -> OfferResponder {
        let app = InstalledApp(bundleID: visor, version: version, build: "1")
        let installer = UpdateInstaller(store: store, system: system, platform: .macOS, handler: nil, requester: visor,
                                        now: { Date(timeIntervalSince1970: 50) })
        return OfferResponder(store: store, app: app, installer: installer, system: system, handler: handler, installHook: installHook)
    }

    // MARK: The database

    func testTheDatabaseMovesToItsThirdMigration() async throws {
        _ = try await store().records()
        let database = try Database(path: temporary.file.path)
        XCTAssertEqual(try database.query("PRAGMA user_version") { $0.int(0) }, [3])
    }

    func testUpdateAutomaticallyIsOffUntilTurnedOn() async throws {
        let store = store()
        var on = try await store.autoUpdating()
        XCTAssertEqual(on, [])
        try await store.setAutoUpdate(true, bundleID: visor)
        try await store.setAutoUpdate(true, bundleID: "com.example.Issues")
        try await store.setAutoUpdate(false, bundleID: "com.example.Issues")
        on = try await store.autoUpdating()
        XCTAssertEqual(on, [visor])
    }

    func testAnAppSaysItAnswersOffers() async throws {
        let store = store()
        var answers = try await store.answersOffers(bundleID: visor)
        XCTAssertFalse(answers, "an app from before 0.13 never says so")
        try await store.recordInstalled(bundleID: visor, version: "0.39.2", build: "1")
        try await store.recordAnswersOffers(bundleID: visor)
        answers = try await store.answersOffers(bundleID: visor)
        XCTAssertTrue(answers)
        let record = try await store.record(bundleID: visor)
        XCTAssertEqual(record?.installedVersion, "0.39.2", "its row is kept")
    }

    /// Of two Applications offering one build, one makes the offer; a newer
    /// build replaces an offer not under way, never one being installed.
    func testAnOfferIsMadeOnceAndReplacedOnlyByANewerBuild() async throws {
        let store = store()
        let first = try await store.makeOffer(bundleID: visor, version: "0.40.1", build: "1", offeredBy: "com.example.Applications")
        let second = try await store.makeOffer(bundleID: visor, version: "0.40.1", build: "1", offeredBy: "com.example.Shireworks")
        XCTAssertEqual(first?.state, .offered)
        XCTAssertNil(second, "the same build: the first Applications carries it out")
        let older = try await store.makeOffer(bundleID: visor, version: "0.40.0", build: "1", offeredBy: "com.example.Shireworks")
        XCTAssertNil(older)
        let newer = try await store.makeOffer(bundleID: visor, version: "0.40.2", build: "1", offeredBy: "com.example.Shireworks")
        XCTAssertEqual(newer?.version, "0.40.2", "not yet answered: the newer build is offered instead")
        try await store.moveOffer(bundleID: visor, version: "0.40.2", build: "1", from: [.offered], to: .installMyself)
        let duringInstall = try await store.makeOffer(bundleID: visor, version: "0.40.3", build: "1", offeredBy: "com.example.Applications")
        XCTAssertNil(duringInstall, "one under way stands")
        try await store.moveOffer(bundleID: visor, version: "0.40.2", build: "1", from: [.installMyself], to: .failed, note: "no")
        let afterFailure = try await store.makeOffer(bundleID: visor, version: "0.40.3", build: "1", offeredBy: "com.example.Applications")
        XCTAssertEqual(afterFailure?.version, "0.40.3")
        let offers = try await store.offers()
        XCTAssertEqual(offers.map(\.offeredBy), ["com.example.Applications"])
    }

    func testAnOfferMovesOnlyFromTheStatesGivenAndOnlyForItsBuild() async throws {
        let store = store()
        _ = try await store.makeOffer(bundleID: visor, version: "0.40.1", build: "1", offeredBy: "com.example.Applications")
        let wrongBuild = try await store.moveOffer(bundleID: visor, version: "0.40.0", build: "1", from: [.offered], to: .goAhead)
        let wrongState = try await store.moveOffer(bundleID: visor, version: "0.40.1", build: "1", from: [.deferred], to: .goAhead)
        XCTAssertFalse(wrongBuild)
        XCTAssertFalse(wrongState)
        let bundle = URL(fileURLWithPath: "/tmp/Offers/Visor.app")
        let handed = try await store.moveOffer(bundleID: visor, version: "0.40.1", build: "1", from: [.offered], to: .handedOver,
                                               bundle: bundle)
        XCTAssertTrue(handed)
        let offer = try await store.offer(bundleID: visor)
        XCTAssertEqual(offer?.state, .handedOver)
        XCTAssertEqual(offer?.bundle, bundle)
    }

    // MARK: The app's answer

    /// No handler: go ahead, at once (the owner, 2026-11-11): Applications
    /// asked through the database, and the app quits.
    func testWithoutAHandlerTheAppGoesAheadAndQuits() async throws {
        let store = store(), system = FakeSystem()
        _ = try await store.makeOffer(bundleID: visor, version: "0.40.1", build: "1", offeredBy: "com.example.Applications")
        try await responder(store, system: system).launched()
        let offer = try await store.offer(bundleID: visor)
        XCTAssertEqual(offer?.state, .goAhead)
        let requests = try await store.installRequests()
        XCTAssertEqual(requests.map(\.version), ["0.40.1"])
        let events = await system.events
        XCTAssertEqual(events, ["changed", "changed", "open Applications", "terminate"])
        let answers = try await store.answersOffers(bundleID: visor)
        XCTAssertTrue(answers)
    }

    func testAHandlerDefersUntilReady() async throws {
        let store = store(), system = FakeSystem()
        _ = try await store.makeOffer(bundleID: visor, version: "0.40.1", build: "1", offeredBy: "com.example.Applications")
        var asked: [String] = []
        let responder = responder(store, system: system, handler: { offer in
            asked.append(offer.version)
            return .deferUntilReady
        })
        try await responder.launched()
        try await responder.look()
        XCTAssertEqual(asked, ["0.40.1"], "asked once")
        var offer = try await store.offer(bundleID: visor)
        XCTAssertEqual(offer?.state, .deferred)
        var events = await system.events
        XCTAssertFalse(events.contains("terminate"))
        try await responder.readyToUpdate()
        offer = try await store.offer(bundleID: visor)
        XCTAssertEqual(offer?.state, .goAhead)
        events = await system.events
        XCTAssertEqual(events.suffix(2), ["open Applications", "terminate"])
    }

    func testAHandlerDeclinesSayingWhy() async throws {
        let store = store(), system = FakeSystem()
        _ = try await store.makeOffer(bundleID: visor, version: "0.40.1", build: "1", offeredBy: "com.example.Applications")
        try await responder(store, system: system, handler: { _ in .decline(reason: "A session is mid-turn") }).launched()
        let offer = try await store.offer(bundleID: visor)
        XCTAssertEqual(offer?.state, .declined)
        XCTAssertEqual(offer?.note, "A session is mid-turn")
        let again = try await store.makeOffer(bundleID: visor, version: "0.40.1", build: "1", offeredBy: "com.example.Applications")
        XCTAssertNil(again, "that build isn't offered again")
        let requests = try await store.installRequests()
        XCTAssertEqual(requests, [])
    }

    /// Install myself: nothing until Applications hands the bundle over,
    /// then the install hook; the app marks it installing, and its next
    /// launch says how it went.
    func testAnAppInstallsItselfAndItsNextLaunchSaysHowItWent() async throws {
        let store = store(), system = FakeSystem()
        _ = try await store.makeOffer(bundleID: visor, version: "0.40.1", build: "1", offeredBy: "com.example.Applications")
        var hooked: [URL?] = []
        let old = responder(store, system: system, handler: { _ in .installMyself }, installHook: { offer in hooked.append(offer.bundle) })
        try await old.launched()
        var offer = try await store.offer(bundleID: visor)
        XCTAssertEqual(offer?.state, .installMyself)
        XCTAssertEqual(hooked, [], "no bundle yet")
        let bundle = URL(fileURLWithPath: "/tmp/Offers/Visor.app")
        try await store.moveOffer(bundleID: visor, version: "0.40.1", build: "1", from: [.installMyself], to: .handedOver, bundle: bundle)
        try await old.look()
        XCTAssertEqual(hooked, [bundle])
        try await old.installing()
        offer = try await store.offer(bundleID: visor)
        XCTAssertEqual(offer?.state, .installing)
        let events = await system.events
        XCTAssertFalse(events.contains("terminate"), "Applications neither quits nor swaps it")

        // The new build's launch: installed.
        try await responder(store, running: "0.40.1", system: system).launched()
        offer = try await store.offer(bundleID: visor)
        XCTAssertEqual(offer?.state, .installed)
        XCTAssertEqual(offer?.bundle, bundle, "kept for Applications to delete")
    }

    func testTheOldBuildLaunchingAfterItsOwnInstallIsAFailure() async throws {
        let store = store(), system = FakeSystem()
        _ = try await store.makeOffer(bundleID: visor, version: "0.40.1", build: "1", offeredBy: "com.example.Applications")
        try await store.moveOffer(bundleID: visor, version: "0.40.1", build: "1", from: [.offered], to: .installing)
        let back = responder(store, system: system)
        try await back.launched()
        var offer = try await store.offer(bundleID: visor)
        XCTAssertEqual(offer?.state, .failed)
        XCTAssertEqual(offer?.note, "0.39.2 is still running after installing 0.40.1")
        try await back.installFailed("Visor Server 0.40.1 did not stay up, so 0.39.2 was put back")
        offer = try await store.offer(bundleID: visor)
        XCTAssertEqual(offer?.note, "Visor Server 0.40.1 did not stay up, so 0.39.2 was put back", "the app's own words")
    }

    func testAnOfferOfABuildNoNewerThanTheOneRunningIsSettled() async throws {
        let store = store(), system = FakeSystem()
        _ = try await store.makeOffer(bundleID: visor, version: "0.40.1", build: "1", offeredBy: "com.example.Applications")
        var asked = false
        try await responder(store, running: "0.40.1", system: system, handler: { _ in asked = true; return .goAhead }).launched()
        XCTAssertFalse(asked)
        let offer = try await store.offer(bundleID: visor)
        XCTAssertEqual(offer?.state, .installed)
    }

    /// Visor's relauncher can put the old build back after the new one has
    /// started (and settled the offer as installed): the old one's launch
    /// makes it a failure, and its note can follow.
    func testTheOldBuildBackAfterTheNewOneStartedIsAFailure() async throws {
        let store = store(), system = FakeSystem()
        _ = try await store.makeOffer(bundleID: visor, version: "0.40.1", build: "1", offeredBy: "com.example.Applications")
        let bundle = URL(fileURLWithPath: "/tmp/Offers/Visor.app")
        try await store.moveOffer(bundleID: visor, version: "0.40.1", build: "1", from: [.offered], to: .installing, bundle: bundle)
        try await responder(store, running: "0.40.1", system: system).launched()
        var offer = try await store.offer(bundleID: visor)
        XCTAssertEqual(offer?.state, .installed)
        let back = responder(store, system: system)
        try await back.launched()
        offer = try await store.offer(bundleID: visor)
        XCTAssertEqual(offer?.state, .failed)
        XCTAssertEqual(offer?.note, "0.39.2 is running again after 0.40.1 was installed")
        try await back.installFailed("Visor Server 0.40.1 did not stay up, so 0.39.2 was put back")
        offer = try await store.offer(bundleID: visor)
        XCTAssertEqual(offer?.note, "Visor Server 0.40.1 did not stay up, so 0.39.2 was put back")
        XCTAssertEqual(offer?.bundle, bundle, "kept for Applications to delete")
    }

    /// An app installed by Applications (no bundle handed over) running its
    /// older build later is not a failure of the offer.
    func testAnOlderBuildLaterIsNoFailureOfAnInstallByApplications() async throws {
        let store = store(), system = FakeSystem()
        _ = try await store.makeOffer(bundleID: visor, version: "0.40.1", build: "1", offeredBy: "com.example.Applications")
        try await store.moveOffer(bundleID: visor, version: "0.40.1", build: "1", from: [.offered], to: .installed)
        try await responder(store, system: system).launched()
        let offer = try await store.offer(bundleID: visor)
        XCTAssertEqual(offer?.state, .installed)
    }

    /// The install hook is called once an offer in a process, however long
    /// the app waits and however many signals come.
    func testTheInstallHookIsCalledOnceAnOffer() async throws {
        let store = store(), system = FakeSystem()
        _ = try await store.makeOffer(bundleID: visor, version: "0.40.1", build: "1", offeredBy: "com.example.Applications")
        try await store.moveOffer(bundleID: visor, version: "0.40.1", build: "1", from: [.offered], to: .handedOver,
                                  bundle: URL(fileURLWithPath: "/tmp/Offers/Visor.app"))
        var calls = 0
        let responder = responder(store, system: system, installHook: { _ in calls += 1 })
        try await responder.launched()
        try await responder.look()
        try await responder.look()
        XCTAssertEqual(calls, 1)
    }
}

