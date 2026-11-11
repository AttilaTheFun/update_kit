import Foundation

/// An app's side of updating automatically on a Mac (docs/Updates.md):
/// answers Applications' offer of its newest build with its handler (go
/// ahead when it has none), carries the answer out, and at each launch
/// settles what came of an offer it was installing. `AppUpdates` runs one;
/// tests run one with a fake system.
@MainActor
public final class OfferResponder {
    public let store: AppGroupStore
    /// The app running.
    public let app: InstalledApp
    /// Asks Applications to install and quits the app (go ahead).
    public let installer: UpdateInstaller
    public let system: any UpdateSystem
    let handler: AutoUpdateHandler?
    let installHook: AutoUpdateInstaller?
    /// The offer being answered or installed, so a signal heard meanwhile
    /// doesn't ask the handler twice.
    private var busy: Set<String> = []

    public init(store: AppGroupStore, app: InstalledApp, installer: UpdateInstaller, system: any UpdateSystem,
                handler: AutoUpdateHandler?, installHook: AutoUpdateInstaller?) {
        self.store = store
        self.app = app
        self.installer = installer
        self.system = system
        self.handler = handler
        self.installHook = installHook
    }

    /// At launch: says this app answers offers, settles one it was
    /// installing (by the version running now, as the process that started
    /// an install may not be the one that finds out how it went), then
    /// looks at the offer as it stands.
    public func launched() async throws {
        try await store.recordAnswersOffers(bundleID: app.bundleID)
        if let offer = try await store.offer(bundleID: app.bundleID) {
            try await settle(offer)
        }
        try await look()
    }

    /// Looks at the app's offer and acts on it: answers a new one, calls the
    /// install hook with one handed over. At launch, on each signal.
    public func look() async throws {
        guard let offer = try await store.offer(bundleID: app.bundleID), !busy.contains(Self.key(offer)) else { return }
        busy.insert(Self.key(offer))
        defer { busy.remove(Self.key(offer)) }
        switch offer.state {
        case .offered:
            // One of a build that isn't newer than this one is no offer.
            guard app.appVersion < offer.appVersion else {
                try await store.moveOffer(bundleID: offer.bundleID, version: offer.version, build: offer.build, from: [.offered],
                                          to: .installed)
                await system.databaseChanged()
                return
            }
            let decision = await handler?(offer) ?? .goAhead
            guard try await store.moveOffer(bundleID: offer.bundleID, version: offer.version, build: offer.build, from: [.offered],
                                            to: decision.state, note: decision.note) else { return }
            await system.databaseChanged()
            if decision == .goAhead { try await goAhead(offer) }
        case .handedOver:
            guard let installHook else { return }
            await installHook(offer)
        default:
            return
        }
    }

    /// After deferring: the app is ready, so it goes ahead now. Nothing
    /// when there's no deferred offer.
    public func readyToUpdate() async throws {
        guard let offer = try await store.offer(bundleID: app.bundleID),
              try await store.moveOffer(bundleID: offer.bundleID, version: offer.version, build: offer.build, from: [.deferred],
                                        to: .goAhead) else { return }
        await system.databaseChanged()
        try await goAhead(offer)
    }

    /// The app is installing the bundle it was handed (just before it
    /// relaunches): its next launch says how that went.
    public func installing() async throws {
        guard let offer = try await store.offer(bundleID: app.bundleID),
              try await store.moveOffer(bundleID: offer.bundleID, version: offer.version, build: offer.build,
                                        from: [.handedOver], to: .installing, bundle: offer.bundle) else { return }
        await system.databaseChanged()
    }

    /// The app's own install failed (it refused the bundle, or its new build
    /// didn't stay up and the old one is back), saying why.
    public func installFailed(_ note: String) async throws {
        guard let offer = try await store.offer(bundleID: app.bundleID),
              try await store.moveOffer(bundleID: offer.bundleID, version: offer.version, build: offer.build,
                                        from: [.installMyself, .handedOver, .installing, .failed], to: .failed, note: note,
                                        bundle: offer.bundle) else { return }
        await system.databaseChanged()
    }

    // MARK: Inside

    /// What a launch says of an offer under way: the build running is the
    /// one offered (or newer), so it's installed; after the app's own
    /// install the older one is running, so it failed.
    func settle(_ offer: UpdateOffer) async throws {
        let states: Set<UpdateOffer.State> = [.goAhead, .handedOver, .installing]
        guard states.contains(offer.state) else { return }
        if app.appVersion >= offer.appVersion {
            try await store.moveOffer(bundleID: offer.bundleID, version: offer.version, build: offer.build, from: states, to: .installed,
                                      bundle: offer.bundle)
        } else if offer.state == .installing {
            try await store.moveOffer(bundleID: offer.bundleID, version: offer.version, build: offer.build, from: [.installing],
                                      to: .failed, note: "\(app.appVersion) is still running after installing \(offer.appVersion)",
                                      bundle: offer.bundle)
        } else {
            return
        }
        await system.databaseChanged()
    }

    /// Go ahead: Applications asked to install the build, and the app quits
    /// at once (`UpdateInstaller`, as the banner's Install).
    private func goAhead(_ offer: UpdateOffer) async throws {
        _ = try await installer.install(AvailableUpdate(bundleID: offer.bundleID, version: offer.version, build: offer.build,
                                                        installURL: nil, installedVersion: app.version, installedBuild: app.build))
    }

    private static func key(_ offer: UpdateOffer) -> String { "\(offer.version) \(offer.build ?? "") \(offer.state.rawValue)" }
}
