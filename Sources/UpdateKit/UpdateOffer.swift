import Foundation

/// Applications offering an app on a Mac its newest build, when the app's
/// "Update automatically" is on (docs/Updates.md, "Updating automatically"):
/// one offer a bundle id, in the shared database, which the app answers
/// (`UpdateDecision`) and Applications carries out.
public struct UpdateOffer: Sendable, Equatable {
    /// Where an offer is, from its making to its outcome.
    public enum State: String, Sendable, CaseIterable {
        /// Made by Applications; the app hasn't answered (it isn't running,
        /// or hasn't heard yet).
        case offered
        /// The app said go ahead: it asks Applications to install and quits.
        case goAhead
        /// The app will say when (`AppUpdates.readyToUpdate()`).
        case deferred
        /// The app won't take this version; the next newer one is offered.
        case declined
        /// The app installs it itself, once Applications has the bundle
        /// ready (`handedOver`).
        case installMyself
        /// The verified, unpacked app is at `bundle` for the app's install
        /// hook.
        case handedOver
        /// The app is installing it: its next launch says how that went.
        case installing
        /// The offered build is the one running.
        case installed
        /// It didn't install; `note` says why.
        case failed

        /// Done with: nothing more happens to this offer.
        public var isSettled: Bool { [.declined, .installed, .failed].contains(self) }
    }

    public var bundleID: String
    public var version: String
    public var build: String?
    public var state: State
    /// Why it was declined, or why it failed.
    public var note: String?
    /// The verified, unpacked app (`handedOver`), in the app group's
    /// container, for an app that installs itself.
    public var bundle: URL?
    /// The Applications that made the offer (its bundle id): the one that
    /// carries it out.
    public var offeredBy: String
    public var offeredAt: Date
    public var updatedAt: Date

    public init(bundleID: String, version: String, build: String?, state: State = .offered, note: String? = nil, bundle: URL? = nil,
                offeredBy: String, offeredAt: Date, updatedAt: Date? = nil) {
        self.bundleID = bundleID
        self.version = version
        self.build = build
        self.state = state
        self.note = note
        self.bundle = bundle
        self.offeredBy = offeredBy
        self.offeredAt = offeredAt
        self.updatedAt = updatedAt ?? offeredAt
    }

    public var appVersion: AppVersion { AppVersion(version, build: build) }
}

/// An app's answer to an offer, from its handler
/// (`AppUpdates.register(autoUpdate:)`).
public enum UpdateDecision: Sendable, Equatable {
    /// The default: the app asks Applications to install it and quits at
    /// once; Applications puts the build in place and opens it again.
    case goAhead
    /// Not now: nothing happens until the app calls
    /// `AppUpdates.readyToUpdate()` (when the user agrees, or work is done).
    case deferUntilReady
    /// Not this version, saying why if it likes; the next newer one is
    /// offered.
    case decline(reason: String?)
    /// The app installs it itself (Visor, which hosts agents a quit would
    /// end): Applications readies the verified bundle, then the app's
    /// install hook (`AppUpdates.register(install:)`) is called with it.
    /// Applications neither quits nor replaces the app.
    case installMyself

    /// The offer's state once the app has answered.
    var state: UpdateOffer.State {
        switch self {
        case .goAhead: .goAhead
        case .deferUntilReady: .deferred
        case .decline: .declined
        case .installMyself: .installMyself
        }
    }

    var note: String? {
        if case .decline(let reason) = self { return reason }
        return nil
    }
}

/// An app's handler of offers: asked once an offer, on the main actor.
public typealias AutoUpdateHandler = @MainActor @Sendable (UpdateOffer) async -> UpdateDecision

/// An app's own install of an offer it said `installMyself` to: called with
/// the offer once its `bundle` is ready (or at the next launch, for an app
/// that was not running), to install when it suits.
public typealias AutoUpdateInstaller = @MainActor @Sendable (UpdateOffer) async -> Void
