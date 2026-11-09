import Observation

/// What the app knows of its own updates, for its update UI (UpdateKitUI's
/// banner and version section, or the app's own): the build running, and
/// what the last check found. `AppUpdates` fills it in; it stays empty in
/// an app that names no app group (`UpdateKitInfo`).
@MainActor
@Observable
public final class UpdateStatus {
    public static let shared = UpdateStatus()

    /// The build running, once `AppUpdates.start` has read it.
    public internal(set) var installed: InstalledApp?
    /// What the last check found; nil before the first.
    public private(set) var lastCheck: UpdateCheck?

    /// A newer build the distributor knows of, to offer.
    public var available: AvailableUpdate? {
        if case .available(let update) = lastCheck { return update }
        return nil
    }

    /// Whether updates are checked at all: the app names an app group and
    /// a check has run.
    public var checks: Bool { lastCheck != nil }

    public init() {}

    /// A check's result.
    public func found(_ check: UpdateCheck) {
        lastCheck = check
    }
}
