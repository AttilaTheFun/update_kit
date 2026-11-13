#if canImport(Darwin)
import Foundation
import os

/// An app's side of its updates, in one call at launch:
///
///     AppUpdates.start()
///
/// The app writes the build it is to the database it shares with
/// Applications (in the app group its Info.plist names, `UpdateKitInfo`), so
/// Applications knows what is installed, and on a Mac answers Applications'
/// offers to update it automatically. It tells of nothing and shows nothing:
/// only Applications (or Shireworks, where it shows Applications) tells of
/// updates (the owner, 2026-11-13). A Mac app that updates itself registers
/// its handler first: `AppUpdates.register(updateHandler:)`.
@MainActor
public final class AppUpdates {
    /// The distributor on the Mac, as the app's Info.plist names it
    /// (`UpdateKitInfo.applicationsBundleIDsKey`): whichever is installed is
    /// asked to install an update.
    public static var macApplicationsBundleIDs: [String] { UpdateKitInfo.mainApplicationsBundleIDs }

    private static var handler: UpdateHandler?
    private static var autoUpdateHandler: AutoUpdateHandler?
    private static var autoUpdateInstaller: AutoUpdateInstaller?
    /// What start set going (UpdateSession: portable, tested on Linux).
    private static var session: UpdateSession?
    private static var responder: OfferResponder? { session?.responder }
    private static var offersWatch: Task<Void, Never>?
    private static let log = Logger(subsystem: "UpdateKit", category: "updates")

    private init() {}

    /// A Mac app's own install of its updates (Shireworks, Visor Runner,
    /// Applications Server): called with the update in place of asking
    /// Applications and quitting. Register before `start`.
    public static func register(updateHandler: @escaping UpdateHandler) {
        handler = updateHandler
    }

    // MARK: Updating automatically (a Mac)

    /// The app's answer to Applications' offers of its newest build, when
    /// its "Update automatically" is on (docs/Updates.md): go ahead (the
    /// default, without a handler: the app quits at once and Applications
    /// puts the build in place and opens it), defer until
    /// `readyToUpdate()`, decline, or install it itself. Register before
    /// `start`.
    public static func register(autoUpdate: @escaping AutoUpdateHandler) {
        autoUpdateHandler = autoUpdate
    }

    /// An app that answers `.installMyself`: called with the offer once its
    /// `bundle` (the verified, unpacked app, in the group's container) is
    /// ready, or at the next launch, to install when it suits. It calls
    /// `installing()` just before it relaunches, or `installFailed(_:)`.
    /// Register before `start`.
    public static func register(install: @escaping AutoUpdateInstaller) {
        autoUpdateInstaller = install
    }

    /// After `.deferUntilReady`: the app is ready, so the update goes ahead
    /// now (the app asks Applications and quits).
    public static func readyToUpdate() async {
        do { try await responder?.readyToUpdate() } catch { log.error("Not updated: \(String(describing: error), privacy: .public)") }
    }

    /// After `.installMyself`: the app is installing the bundle it was given
    /// and is about to relaunch. Its next launch says whether it worked: the
    /// version offered running is installed; the older one, failed.
    public static func installing() async {
        do { try await responder?.installing() } catch { log.error("Not marked installing: \(String(describing: error), privacy: .public)") }
    }

    /// After `.installMyself`: the app's install failed, saying why (it
    /// refused the bundle; at a launch, its new build didn't stay up and the
    /// old one was put back). Applications shows it on the app's page.
    public static func installFailed(_ note: String) async {
        do { try await responder?.installFailed(note) } catch { log.error("Not marked failed: \(String(describing: error), privacy: .public)") }
    }

    /// Starts at launch: writes the app's build, and on a Mac answers
    /// Applications' offers, now and as they come. The app group is the one
    /// given, else the one the app's Info.plist names (`UpdateKitInfo`); with
    /// neither, it does nothing at all: a build from the public source,
    /// whose distributor's CI didn't stamp one in. An app without the
    /// group's container (its entitlements, its profile) logs why and does
    /// nothing.
    public static func start(appGroup given: String? = nil) {
        guard session == nil, let app = InstalledApp.main() else { return }
        guard let appGroup = given ?? UpdateKitInfo.mainAppGroup else {
            log.debug("No app group in the Info.plist (\(UpdateKitInfo.appGroupKey, privacy: .public)): no updates")
            return
        }
        let store: AppGroupStore
        do {
            store = try AppGroupStore.appGroup(appGroup)
        } catch {
            log.error("No updates: \(String(describing: error), privacy: .public)")
            return
        }
        let signal = UpdateSignal(appGroup: appGroup)
        // The handlers looked up as each is needed, not when start ran: one
        // registered after start is asked all the same.
        let session = UpdateSession(store: store, app: app, signal: signal,
                                    system: AppleUpdateSystem(signal: signal, applicationsBundleIDs: macApplicationsBundleIDs),
                                    handler: { AppUpdates.handler }, autoUpdate: { AppUpdates.autoUpdateHandler },
                                    installHook: { AppUpdates.autoUpdateInstaller })
        Self.session = session
        Task { await check() }
        // Offers are a Mac's: answered at launch and on each signal, by
        // every app (Applications too, of its own updates).
        #if os(macOS)
        let log = Self.log
        Task { @MainActor in
            offersWatch = await session.answerOffers { note in log.error("\(note, privacy: .public)") }
        }
        #endif
    }

    /// Writes the build again now.
    public static func check() async {
        guard let session else { return }
        do {
            _ = try await session.check()
        } catch {
            log.error("The update check failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Installs an update: the handler's way, iOS's install link, or
    /// Applications asked and the app quit (`UpdateInstaller`).
    public static func install(_ update: AvailableUpdate) async {
        guard let session else { return }
        do {
            _ = try await session.install(update)
        } catch {
            log.error("The update did not install: \(String(describing: error), privacy: .public)")
        }
    }

    /// Applications asked to install the update (an install request, the
    /// group told, Applications opened) and the app quit: the Mac's way,
    /// whatever handler is registered. For an app whose update handler
    /// waits (Shireworks: its work drained first), then hands the install
    /// to Applications, which puts the build in place and opens the app
    /// again. On an iPhone or an iPad it opens the install link, as
    /// `install` does.
    public static func installThroughApplications(_ update: AvailableUpdate) async throws {
        guard let session else { throw UpdateInstallError.notStarted }
        _ = try await session.installThroughApplications(update)
    }
}
#endif
