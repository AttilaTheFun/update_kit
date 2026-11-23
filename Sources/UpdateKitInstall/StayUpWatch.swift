import Foundation

/// A new build watched once it's in place (docs/Installing.md, "Staying up"): what the watcher, started by the service
/// and outliving it and the app, is to do.
public struct StayUpWatch: Sendable, Codable, Equatable {
    /// The install watched: its destination, backup and executable's digest.
    public var install: InstallResult
    public var bundleID: String
    /// The app that asked, quitting to make way: the watcher waits for it to exit (up to `quitSeconds`), then opens
    /// the new build.
    public var quittingPID: Int32
    public var quitSeconds: TimeInterval
    /// How long the new build's process must find to start.
    public var startSeconds: TimeInterval
    /// A server's: a URL the new build answers once it's up (any HTTP status counts; no answer doesn't), asked until
    /// `firstAnswerSeconds`. Nil: running is enough.
    public var healthURL: URL?
    public var firstAnswerSeconds: TimeInterval
    /// Whether the listener on the health URL's port, where it can be seen, must be the new build's process (so an
    /// old process still answering doesn't count).
    public var listenerMustBeWatched: Bool
    /// How long it must then stay running: "stayed up".
    public var seconds: TimeInterval
    /// The lock held for the whole watch (`WatchLock`): a line `<pid> <started-epoch-seconds>`, counting only while
    /// that pid is alive.
    public var lockPath: String
    /// Where the outcome goes (`WatchNote`, JSON), for the app's next launch.
    public var notePath: String
    /// The install's policy, for the restore's checks: the service's own, set by it (`StayUpWatcher.checked`), whatever
    /// the app sent.
    public var policy: InstallPolicy?

    public init(install: InstallResult, bundleID: String, quittingPID: Int32, quitSeconds: TimeInterval = 60,
                startSeconds: TimeInterval = 30, healthURL: URL? = nil, firstAnswerSeconds: TimeInterval = 600,
                listenerMustBeWatched: Bool = false, seconds: TimeInterval = 120, lockPath: String, notePath: String,
                policy: InstallPolicy? = nil) {
        self.install = install
        self.bundleID = bundleID
        self.quittingPID = quittingPID
        self.quitSeconds = quitSeconds
        self.startSeconds = startSeconds
        self.healthURL = healthURL
        self.firstAnswerSeconds = firstAnswerSeconds
        self.listenerMustBeWatched = listenerMustBeWatched
        self.seconds = seconds
        self.lockPath = lockPath
        self.notePath = notePath
        self.policy = policy
    }
}

/// How a watch ended, written to its note for the app's next launch.
public struct WatchNote: Sendable, Codable, Equatable {
    public enum Outcome: String, Sendable, Codable {
        /// The new build stayed up; its backup was discarded.
        case stayedUp
        /// It didn't, and the earlier build is back (`reason`: why it didn't).
        case restored
        /// It didn't, and the earlier build couldn't be put back (`reason`: both whys).
        case restoreFailed
    }

    public var outcome: Outcome
    public var reason: String?
    public var bundleID: String
    /// The build watched: its executable's digest.
    public var executableSHA256: String
    public var at: Date

    public init(outcome: Outcome, reason: String?, bundleID: String, executableSHA256: String, at: Date) {
        self.outcome = outcome
        self.reason = reason
        self.bundleID = bundleID
        self.executableSHA256 = executableSHA256
        self.at = at
    }

    /// The note at `path`, if one is there and readable.
    public static func read(_ path: String) -> WatchNote? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(WatchNote.self, from: data)
    }

    var json: String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: (try? encoder.encode(self)) ?? Data(), as: UTF8.self)
    }
}

/// What the watcher and its lock look at and do: the Mac (MacWatchSystem), or a test's, whose clock its sleeping moves.
public protocol WatchSystem {
    /// The install rules' system, for the restore and the discard.
    var files: any BundleInstallSystem { get }
    func now() -> Date
    func sleep(_ seconds: TimeInterval)
    var ownPID: Int32 { get }
    /// Whether a process of that id runs (`kill(pid, 0)`).
    func isAlive(_ pid: Int32) -> Bool
    /// SIGTERM sent to it.
    func terminate(_ pid: Int32)
    func read(_ path: String) -> String?
    /// `text` written to `path` whole (replacing it in one rename).
    func write(_ text: String, to path: String) throws
    func remove(_ path: String)
    /// The app at `path` opened (LaunchServices): whether it was.
    func open(app path: String) -> Bool
    /// The processes running the executable at `path`.
    func pids(runningExecutable path: String) -> [Int32]
    /// Whether anything answers `url` over HTTP, any status.
    func answers(_ url: URL) -> Bool
    /// The process listening on `url`'s port, where it can be seen; nil when it can't.
    func listenerPID(of url: URL) -> Int32?
}
