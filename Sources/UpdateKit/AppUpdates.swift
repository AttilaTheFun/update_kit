#if canImport(UserNotifications)
import Foundation
import UserNotifications
import os
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// An app's updates, from Applications, in one call at launch:
///
///     AppUpdates.start()
///
/// The app writes the build it is to the database it shares with
/// Applications (in the app group its Info.plist names, `UpdateKitInfo`), and
/// when Applications has said of a newer build, tells the user with a local
/// notification while the app is in the foreground: at launch, each time
/// it comes forward, and when Applications syncs a newer one while it runs.
/// Opening the notification, or its Install, installs the update
/// (`UpdateInstaller`). A Mac app that updates itself registers its handler
/// first: `AppUpdates.register(updateHandler:)`.
@MainActor
public final class AppUpdates {
    /// The distributor on the Mac, as the app's Info.plist names it
    /// (`UpdateKitInfo.applicationsBundleIDsKey`): whichever is installed is
    /// asked to install an update.
    public static var macApplicationsBundleIDs: [String] { UpdateKitInfo.mainApplicationsBundleIDs }

    private static var handler: UpdateHandler?
    private static var autoUpdateHandler: AutoUpdateHandler?
    private static var autoUpdateInstaller: AutoUpdateInstaller?
    private static var responder: OfferResponder?
    private static var store: AppGroupStore?
    private static var signal: UpdateSignal?
    private static var checker: UpdateChecker?
    /// Kept: the notification center holds its delegate weakly.
    private static var delegate: UpdateNotificationDelegate?
    private static var watching: Task<Void, Never>?
    private static var offersWatch: Task<Void, Never>?
    private static var foregroundObserver: (any NSObjectProtocol)?
    private static let log = Logger(subsystem: "UpdateKit", category: "updates")

    private init() {}

    /// A Mac app's own install of its updates (OS Server, Visor Runner,
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

    /// Starts at launch: writes the app's build and checks for a newer one
    /// now, when it comes to the foreground and when Applications syncs.
    /// `tellsOfUpdates: false` only writes the build (Applications itself,
    /// which tells of its own updates). The app group is the one given,
    /// else the one the app's Info.plist names (`UpdateKitInfo`); with
    /// neither, it does nothing at all: a build from the public source,
    /// whose distributor's CI didn't stamp one in. An app without the
    /// group's container (its entitlements, its profile) logs why and does
    /// nothing. `UpdateStatus.shared` says what each check found, for the
    /// app's own update UI (UpdateKitUI).
    public static func start(appGroup given: String? = nil, tellsOfUpdates: Bool = true) {
        guard checker == nil, let app = InstalledApp.main() else { return }
        UpdateStatus.shared.installed = app
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
        let checker = UpdateChecker(store: store, app: app, presenter: NotificationPresenter(appName: appName), tells: tellsOfUpdates)
        Self.store = store
        Self.signal = signal
        Self.checker = checker
        Task { await check() }
        // Offers are a Mac's: answered at launch and on each signal, by
        // every app (Applications too, of its own updates).
        #if os(macOS)
        let responder = OfferResponder(store: store, app: app,
                                       installer: UpdateInstaller(store: store,
                                                                  system: AppleUpdateSystem(signal: signal,
                                                                                            applicationsBundleIDs: macApplicationsBundleIDs),
                                                                  handler: handler, requester: app.bundleID),
                                       system: AppleUpdateSystem(signal: signal, applicationsBundleIDs: macApplicationsBundleIDs),
                                       handler: autoUpdateHandler, installHook: autoUpdateInstaller)
        Self.responder = responder
        Task {
            do { try await responder.launched() } catch { log.error("The offer was not looked at: \(String(describing: error), privacy: .public)") }
        }
        offersWatch = Task {
            for await _ in signal.changes() {
                do { try await responder.look() } catch { log.error("The offer was not looked at: \(String(describing: error), privacy: .public)") }
            }
        }
        #endif
        guard tellsOfUpdates else { return }
        let center = UNUserNotificationCenter.current()
        if center.delegate == nil {
            let delegate = UpdateNotificationDelegate()
            Self.delegate = delegate
            center.delegate = delegate
        }
        Task { await addCategory() }
        foregroundObserver = NotificationCenter.default.addObserver(forName: becameActive, object: nil, queue: .main) { _ in
            Task { @MainActor in await AppUpdates.check() }
        }
        watching = Task {
            for await _ in signal.changes() { await check() }
        }
    }

    /// Checks again now.
    public static func check() async {
        guard let checker else { return }
        do {
            let found = try await checker.check()
            UpdateStatus.shared.found(found)
        } catch {
            log.error("The update check failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Installs an update: the handler's way, iOS's install link, or
    /// Applications asked and the app quit (`UpdateInstaller`).
    public static func install(_ update: AvailableUpdate) async {
        guard let store, let signal, let checker else { return }
        let installer = UpdateInstaller(store: store, system: AppleUpdateSystem(signal: signal, applicationsBundleIDs: macApplicationsBundleIDs),
                                        handler: handler, requester: checker.app.bundleID)
        do {
            _ = try await installer.install(update)
        } catch {
            log.error("The update did not install: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: For an app with a notification delegate of its own

    /// Whether a notification is an update's: shown in the foreground
    /// (`[.banner, .list, .sound]`) by an app's own delegate.
    public nonisolated static func isUpdateNotification(_ notification: UNNotification) -> Bool {
        notification.request.content.categoryIdentifier == NotificationPresenter.category
    }

    /// The update a notification the user opened (or chose Install on)
    /// offers, for `install`; nil for any other.
    public nonisolated static func update(from response: UNNotificationResponse) -> AvailableUpdate? {
        guard isUpdateNotification(response.notification),
              [UNNotificationDefaultActionIdentifier, NotificationPresenter.installAction].contains(response.actionIdentifier) else { return nil }
        return AvailableUpdate(userInfo: response.notification.request.content.userInfo)
    }

    // MARK: Inside

    /// The update notification's category beside the app's own. An app that
    /// sets its categories after `start` includes
    /// `NotificationPresenter.notificationCategory` in them.
    private nonisolated static func addCategory() async {
        let center = UNUserNotificationCenter.current()
        let existing = await center.notificationCategories().filter { $0.identifier != NotificationPresenter.category }
        center.setNotificationCategories(existing.union([NotificationPresenter.notificationCategory]))
    }

    private static var appName: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? Bundle.main.bundleIdentifier ?? "This app"
    }

    private static var becameActive: Notification.Name {
        #if canImport(UIKit)
        return UIApplication.didBecomeActiveNotification
        #else
        return NSApplication.didBecomeActiveNotification
        #endif
    }
}
#endif
