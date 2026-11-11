import Foundation
import SwiftSQL

/// The database Applications and the apps it distributes share, in their
/// app group's container: each app's newest build, which Applications
/// writes, and the build installed, which each app writes of itself
/// (`AppRecord`); and, on a Mac, the apps' install requests to
/// Applications (`InstallRequest`).
///
/// Several processes use it at once: SQLite in write-ahead-log mode, a busy
/// timeout for another's write, and a connection opened for each call and
/// closed after it. None is held open, so no lock on a file in the shared
/// container is held while an iPhone app is suspended, which iOS ends the
/// app for (0xdead10cc); opening one costs less than the launch it serves.
public actor AppGroupStore {
    /// The database's name in the group's container.
    /// Its name from before the library was UpdateKit, kept: Applications
    /// and every app share this one file.
    public static let fileName = "ApplicationUpdates.sqlite"

    public let fileURL: URL
    private let now: @Sendable () -> Date
    /// The tables made in this process already.
    private var prepared = false

    /// The database at `fileURL`, made on first use. `now` is when a write
    /// happens (tests fix it).
    public init(fileURL: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.fileURL = fileURL
        self.now = now
    }

    #if canImport(Darwin)
    /// The database in an app group's container: the one given, else the
    /// one the app's Info.plist names (`UpdateKitInfo`). Throws when there
    /// is none, or the app has no such container: its entitlements and
    /// profile don't grant the group.
    public static func appGroup(_ given: String? = nil) throws -> AppGroupStore {
        guard let identifier = given ?? UpdateKitInfo.mainAppGroup else { throw AppGroupStoreError.noAppGroup }
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) else {
            throw AppGroupStoreError.noContainer(appGroup: identifier)
        }
        return AppGroupStore(fileURL: container.appendingPathComponent(fileName))
    }
    #endif

    // MARK: Apps

    /// The app's installed build, its version and its variant, written when
    /// it differs from what the row says (another variant of the same
    /// version too: the last launched is the one installed): whether it did.
    @discardableResult
    public func recordInstalled(bundleID: String, version: String, build: String?, variant: String? = nil) throws -> Bool {
        try withConnection { connection in
            try connection.run("""
                INSERT INTO apps (bundle_id, installed_version, installed_build, installed_variant, updated_at) VALUES (?1, ?2, ?3, ?4, ?5)
                ON CONFLICT (bundle_id) DO UPDATE SET installed_version = excluded.installed_version,
                    installed_build = excluded.installed_build, installed_variant = excluded.installed_variant,
                    updated_at = excluded.updated_at
                WHERE installed_version IS NOT excluded.installed_version OR installed_build IS NOT excluded.installed_build
                    OR installed_variant IS NOT excluded.installed_variant
                """, bundleID, version, build, variant, now().timeIntervalSince1970) > 0
        }
    }

    /// The newest builds, as Applications synced them, each written where it
    /// differs, in one transaction: whether any did.
    @discardableResult
    public func setLatest(_ builds: [LatestBuild]) throws -> Bool {
        let time = now().timeIntervalSince1970
        return try withConnection { connection in
            try connection.transaction(.immediate) { connection in
                var changed = false
                for build in builds {
                    let rows = try connection.run("""
                        INSERT INTO apps (bundle_id, latest_version, latest_build, install_url, updated_at) VALUES (?1, ?2, ?3, ?4, ?5)
                        ON CONFLICT (bundle_id) DO UPDATE SET latest_version = excluded.latest_version,
                            latest_build = excluded.latest_build, install_url = excluded.install_url, updated_at = excluded.updated_at
                        WHERE latest_version IS NOT excluded.latest_version OR latest_build IS NOT excluded.latest_build
                            OR install_url IS NOT excluded.install_url
                        """, build.bundleID, build.version, build.build, build.installURL?.absoluteString, time)
                    changed = changed || rows > 0
                }
                return changed
            }
        }
    }

    /// An app's row, or nil when neither it nor Applications has written one.
    public func record(bundleID: String) throws -> AppRecord? {
        try withConnection { connection in
            try connection.query("SELECT \(Self.columns) FROM apps WHERE bundle_id = ?1", bundleID, row: Self.record).first
        }
    }

    /// Every app's row, by bundle id.
    public func records() throws -> [AppRecord] {
        try withConnection { connection in
            try connection.query("SELECT \(Self.columns) FROM apps ORDER BY bundle_id", row: Self.record)
        }
    }

    // MARK: Install requests (the Mac)

    /// Asks Applications to install an app: replaces the app's earlier request.
    public func requestInstall(_ request: InstallRequest) throws {
        try withConnection { connection in
            try connection.run("""
                INSERT OR REPLACE INTO requests (bundle_id, version, build, requested_by, requested_at) VALUES (?1, ?2, ?3, ?4, ?5)
                """, request.bundleID, request.version, request.build, request.requestedBy, request.requestedAt.timeIntervalSince1970)
        }
    }

    /// Takes back an app's request (Applications could not be opened).
    public func cancelInstallRequest(bundleID: String) throws {
        try withConnection { connection in
            try connection.run("DELETE FROM requests WHERE bundle_id = ?1", bundleID)
        }
    }

    /// The requests waiting, oldest first, left in place.
    public func installRequests() throws -> [InstallRequest] {
        try withConnection { try Self.requests($0) }
    }

    /// The requests waiting, oldest first, taken: each goes to one taker,
    /// however many copies of Applications look at once.
    public func takeInstallRequests() throws -> [InstallRequest] {
        try withConnection { connection in
            try connection.transaction(.immediate) { connection in
                let taken = try Self.requests(connection)
                try connection.execute("DELETE FROM requests")
                return taken
            }
        }
    }

    // MARK: Updating automatically (the Mac)

    /// Turns an app's "Update automatically" on or off: shared by every
    /// Applications (the app, Shireworks' tab).
    public func setAutoUpdate(_ enabled: Bool, bundleID: String) throws {
        let time = now().timeIntervalSince1970
        try withConnection { connection in
            try connection.run("""
                INSERT INTO auto_update (bundle_id, enabled, updated_at) VALUES (?1, ?2, ?3)
                ON CONFLICT (bundle_id) DO UPDATE SET enabled = excluded.enabled, updated_at = excluded.updated_at
                """, bundleID, enabled ? 1 : 0, time)
        }
    }

    /// The apps whose "Update automatically" is on (off for any not here).
    public func autoUpdating() throws -> Set<String> {
        try withConnection { connection in
            Set(try connection.query("SELECT bundle_id FROM auto_update WHERE enabled = 1") { $0.text(0) ?? "" })
        }
    }

    /// Says that this app answers offers (UpdateKit 0.13 and later), at its
    /// launch: Applications then asks it, while it runs, rather than waiting
    /// for it to quit.
    public func recordAnswersOffers(bundleID: String) throws {
        let time = now().timeIntervalSince1970
        try withConnection { connection in
            try connection.run("""
                INSERT INTO apps (bundle_id, answers_offers, updated_at) VALUES (?1, 1, ?2)
                ON CONFLICT (bundle_id) DO UPDATE SET answers_offers = 1 WHERE answers_offers IS NOT 1
                """, bundleID, time)
        }
    }

    /// Whether an app has said it answers offers.
    public func answersOffers(bundleID: String) throws -> Bool {
        try withConnection { connection in
            try connection.query("SELECT answers_offers FROM apps WHERE bundle_id = ?1", bundleID) { $0.int(0) }.first == 1
        }
    }

    /// Makes an offer, unless there is one already of this build or a newer
    /// one, or the app declined this build: the offer made, or nil. In one
    /// transaction that takes the write lock first, so of two Applications
    /// offering at once one makes it, and carries it out.
    public func makeOffer(bundleID: String, version: String, build: String?, offeredBy: String) throws -> UpdateOffer? {
        let time = now()
        let offered = AppVersion(version, build: build)
        return try withConnection { connection in
            try connection.transaction(.immediate) { connection in
                if let existing = try Self.offer(bundleID, connection) {
                    // A settled offer of an older build is replaced; any other
                    // of an older build too, once that build is overtaken (a
                    // deferred one is offered again as the newer build).
                    // One of this build or newer stands.
                    guard existing.appVersion < offered else { return nil }
                    guard [.offered, .deferred, .declined, .installed, .failed].contains(existing.state) else { return nil }
                }
                let offer = UpdateOffer(bundleID: bundleID, version: version, build: build, offeredBy: offeredBy, offeredAt: time)
                try connection.run("""
                    INSERT OR REPLACE INTO offers (bundle_id, version, build, state, note, bundle_path, offered_by, offered_at, updated_at)
                    VALUES (?1, ?2, ?3, ?4, NULL, NULL, ?5, ?6, ?6)
                    """, bundleID, version, build, offer.state.rawValue, offeredBy, time.timeIntervalSince1970)
                return offer
            }
        }
    }

    /// An app's offer, or nil.
    public func offer(bundleID: String) throws -> UpdateOffer? {
        try withConnection { try Self.offer(bundleID, $0) }
    }

    /// Every offer, by bundle id.
    public func offers() throws -> [UpdateOffer] {
        try withConnection { connection in
            try connection.query("SELECT \(Self.offerColumns) FROM offers ORDER BY bundle_id", row: Self.offer)
        }
    }

    /// Moves an offer on, if it is still of this build and in one of the
    /// states given (another process may have moved it first): whether it
    /// did. `note` and `bundle` are written as given (nil clears them).
    @discardableResult
    public func moveOffer(bundleID: String, version: String, build: String?, from states: Set<UpdateOffer.State>,
                          to state: UpdateOffer.State, note: String? = nil, bundle: URL? = nil) throws -> Bool {
        let time = now().timeIntervalSince1970
        return try withConnection { connection in
            try connection.transaction(.immediate) { connection in
                guard let existing = try Self.offer(bundleID, connection), existing.version == version, existing.build == build,
                      states.contains(existing.state) else { return false }
                try connection.run("""
                    UPDATE offers SET state = ?2, note = ?3, bundle_path = ?4, updated_at = ?5 WHERE bundle_id = ?1
                    """, bundleID, state.rawValue, note, bundle?.path, time)
                return true
            }
        }
    }

    /// Forgets an app's offer.
    public func removeOffer(bundleID: String) throws {
        try withConnection { connection in
            try connection.run("DELETE FROM offers WHERE bundle_id = ?1", bundleID)
        }
    }

    // MARK: The connection

    /// Opens the database for `body` and closes it after; the tables made
    /// first, the first time in this process.
    @discardableResult
    private func withConnection<T>(_ body: (Connection) throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let database = try Database(path: fileURL.path)
        defer { database.close() }
        return try database.withConnection { connection in
            if !prepared {
                try StoreSchema.prepare(connection)
                prepared = true
            }
            return try body(connection)
        }
    }

    private static let columns = "bundle_id, latest_version, latest_build, install_url, installed_version, installed_build, updated_at, installed_variant"

    private static func record(_ row: Row) -> AppRecord {
        AppRecord(bundleID: row.text(0) ?? "", latestVersion: row.text(1), latestBuild: row.text(2),
                  installURL: row.text(3).flatMap(URL.init(string:)), installedVersion: row.text(4), installedBuild: row.text(5),
                  installedVariant: row.text(7), updatedAt: Date(timeIntervalSince1970: row.double(6)))
    }

    private static let offerColumns = "bundle_id, version, build, state, note, bundle_path, offered_by, offered_at, updated_at"

    private static func offer(_ bundleID: String, _ connection: Connection) throws -> UpdateOffer? {
        try connection.query("SELECT \(offerColumns) FROM offers WHERE bundle_id = ?1", bundleID, row: offer).first
    }

    private static func offer(_ row: Row) -> UpdateOffer {
        UpdateOffer(bundleID: row.text(0) ?? "", version: row.text(1) ?? "", build: row.text(2),
                    state: UpdateOffer.State(rawValue: row.text(3) ?? "") ?? .offered, note: row.text(4),
                    bundle: row.text(5).map { URL(fileURLWithPath: $0) }, offeredBy: row.text(6) ?? "",
                    offeredAt: Date(timeIntervalSince1970: row.double(7)), updatedAt: Date(timeIntervalSince1970: row.double(8)))
    }

    private static func requests(_ connection: Connection) throws -> [InstallRequest] {
        try connection.query("SELECT bundle_id, version, build, requested_by, requested_at FROM requests ORDER BY requested_at, bundle_id") { row in
            InstallRequest(bundleID: row.text(0) ?? "", version: row.text(1) ?? "", build: row.text(2), requestedBy: row.text(3) ?? "",
                           requestedAt: Date(timeIntervalSince1970: row.double(4)))
        }
    }
}
