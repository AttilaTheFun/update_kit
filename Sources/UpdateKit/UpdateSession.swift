import Foundation

/// What `AppUpdates.start` sets going, apart from Apple's system: the
/// database, the signal, the check (the build written), and (on a Mac) the
/// answering of offers, and how an update installs: the update handler as
/// it is when asked, else the platform's way. Portable, so its wiring is
/// tested on Linux with a fake system; `AppUpdates` makes one with Apple's.
@MainActor
public final class UpdateSession {
    public let store: AppGroupStore
    public let app: InstalledApp
    public let signal: UpdateSignal
    public let checker: UpdateChecker
    public let system: any UpdateSystem
    public let platform: UpdatePlatform
    /// The update handler, looked up each time one is needed: a handler
    /// registered after start is used all the same.
    private let handler: @MainActor () -> UpdateHandler?
    private let autoUpdate: @MainActor () -> AutoUpdateHandler?
    private let installHook: @MainActor () -> AutoUpdateInstaller?
    private let now: @Sendable () -> Date
    /// The offers' answerer, once `answerOffers` has made it (a Mac's).
    public private(set) var responder: OfferResponder?

    public init(store: AppGroupStore, app: InstalledApp, signal: UpdateSignal, system: any UpdateSystem,
                platform: UpdatePlatform = .current,
                handler: @escaping @MainActor () -> UpdateHandler? = { nil },
                autoUpdate: @escaping @MainActor () -> AutoUpdateHandler? = { nil },
                installHook: @escaping @MainActor () -> AutoUpdateInstaller? = { nil },
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.app = app
        self.signal = signal
        self.system = system
        self.platform = platform
        self.handler = handler
        self.autoUpdate = autoUpdate
        self.installHook = installHook
        self.now = now
        checker = UpdateChecker(store: store, app: app)
    }

    /// The app's build written, and what Applications knows of a newer one.
    public func check() async throws -> UpdateCheck {
        try await checker.check()
    }

    /// Installs an update: the update handler's way, if one is registered,
    /// else the platform's (`UpdateInstaller`).
    @discardableResult
    public func install(_ update: AvailableUpdate) async throws -> InstallOutcome {
        try await installer(handler: handler()).install(update)
    }

    /// Installs an update the platform's way, whatever handler is
    /// registered: on a Mac, Applications asked and the app quit.
    @discardableResult
    public func installThroughApplications(_ update: AvailableUpdate) async throws -> InstallOutcome {
        try await installer(handler: nil).install(update)
    }

    /// A Mac's: the offers answered, now (at launch: an install this app
    /// started is settled first) and each time the group's signal comes.
    /// Go ahead installs with the update handler as it is then, else
    /// through Applications. Returns the task that watches the signal.
    @discardableResult
    public func answerOffers(failed: @escaping @Sendable (String) -> Void = { _ in }) async -> Task<Void, Never> {
        let goAhead = installer(handler: { [weak self] update in
            // The handler as it is when go ahead comes, else the Mac's way.
            guard let self else { throw UpdateInstallError.notStarted }
            if let registered = await MainActor.run(body: { self.handler() }) {
                try await registered(update)
            } else {
                _ = try await self.installThroughApplications(update)
            }
        })
        let responder = OfferResponder(store: store, app: app, installer: goAhead, system: system,
                                       handler: { [weak self] offer in await (self?.autoUpdate()?(offer) ?? .goAhead) },
                                       installHook: { [weak self] offer in await self?.installHook()?(offer) })
        self.responder = responder
        do { try await responder.launched() } catch { failed("The offer was not looked at: \(error)") }
        let signal = self.signal
        return Task { @MainActor in
            for await _ in signal.changes() {
                do { try await responder.look() } catch { failed("The offer was not looked at: \(error)") }
            }
        }
    }

    private func installer(handler: UpdateHandler?) -> UpdateInstaller {
        UpdateInstaller(store: store, system: system, platform: platform, handler: handler, requester: app.bundleID, now: now)
    }
}
