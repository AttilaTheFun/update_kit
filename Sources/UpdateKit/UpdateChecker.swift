/// The running app's check at launch: its installed build written to the
/// shared database (so Applications knows what is installed here), and
/// what Applications knows of a newer one decided. Nothing is told: only
/// Applications (or Shireworks, where it shows Applications) tells of
/// updates (the owner, 2026-11-13). An actor: the database is read and
/// written off the main actor.
public actor UpdateChecker {
    public let store: AppGroupStore
    public let app: InstalledApp

    public init(store: AppGroupStore, app: InstalledApp) {
        self.store = store
        self.app = app
    }

    /// Writes the installed build and decides.
    @discardableResult
    public func check() async throws -> UpdateCheck {
        try await store.recordInstalled(bundleID: app.bundleID, version: app.version, build: app.build, variant: app.variant)
        return UpdateCheck.decide(record: try await store.record(bundleID: app.bundleID), installed: app)
    }
}
