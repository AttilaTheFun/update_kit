import Foundation

/// What an installer service installs, from where, and how it checks it: the service's own, never the caller's
/// (docs/Installing.md).
public struct InstallPolicy: Sendable, Codable, Equatable {
    /// The apps it installs, exactly: each bundle id with the one name it goes to `<applications>/<name>.app` by.
    public var apps: [String: String]
    /// The folders a zip may be in, each with its links resolved (the app's sandbox container, an app group's
    /// container): a zip anywhere else, or reached through a link out of them, is refused.
    public var zipFolders: [String]
    public var signing: Signing
    /// Whether a build may replace a newer one (`CFBundleVersion` lower): a person choosing an older version in a
    /// distributor's app. An app updating itself never does (restore is the one way back).
    public var allowsDowngrade: Bool
    /// Whether the app must be at its destination already: an app updating itself installs nothing new.
    public var updateOnly: Bool
    /// Where apps go.
    public var applications: String
    /// How long unpacking may take, in seconds, before ditto is stopped and the install refused.
    public var unpackTimeLimit: TimeInterval
    /// The largest zip taken, and the most its app may unpack to, in bytes.
    public var maxZipBytes: Int
    public var maxUnpackedBytes: Int
    /// How long a backup nobody discarded or restored (and nothing runs from) is kept before a later install sweeps
    /// it, in seconds.
    public var backupLifetime: TimeInterval
    /// What an app's earlier bundle ids added to its own (`.Beta`, say): a copy at the app's name with one of them is
    /// the same app, which an install replaces.
    public var earlierIDSuffixes: [String]
    /// A watch's lock and note (`StayUpWatch`), in a folder the sandboxed app can't replace (never its container):
    /// nil, no watches.
    public var watchLockPath: String?
    public var watchNotePath: String?

    /// How a build's signature is checked. Every mode requires Apple's anchor and the service's own team.
    public enum Signing: String, Sendable, Codable {
        /// The team's Developer ID Application certificate, and notarized (refused if notarization can't be checked).
        case developerID
        /// The team's certificate of any kind Apple issues (a development build's).
        case team
        /// Ad hoc builds alone, for a test build of the service with no team: honoured only in a debug build of this
        /// library, refused everywhere else.
        case adHocForTests
    }

    public init(apps: [String: String], zipFolders: [String], signing: Signing = .developerID, allowsDowngrade: Bool = false,
                updateOnly: Bool = false, applications: String = "/Applications", unpackTimeLimit: TimeInterval = 300,
                maxZipBytes: Int = 2 << 30, maxUnpackedBytes: Int = 8 << 30, backupLifetime: TimeInterval = 86_400,
                earlierIDSuffixes: [String] = [], watchLockPath: String? = nil, watchNotePath: String? = nil) {
        self.apps = apps
        self.zipFolders = zipFolders
        self.signing = signing
        self.allowsDowngrade = allowsDowngrade
        self.updateOnly = updateOnly
        self.applications = applications
        self.unpackTimeLimit = unpackTimeLimit
        self.maxZipBytes = maxZipBytes
        self.maxUnpackedBytes = maxUnpackedBytes
        self.backupLifetime = backupLifetime
        self.earlierIDSuffixes = earlierIDSuffixes
        self.watchLockPath = watchLockPath
        self.watchNotePath = watchNotePath
    }

    /// Whether it installs `bundleID`, by `name`.
    public func installs(_ bundleID: String, name: String) -> Bool { apps[bundleID] == name }

    /// Whether `other` is `bundleID`'s app: the same id, or one of its earlier ones.
    public func isSameApp(_ other: String, as bundleID: String) -> Bool {
        other == bundleID || earlierIDSuffixes.contains { bundleID + $0 == other }
    }

    /// Where the app named `name` goes.
    public func destination(name: String) -> String { "\(applications)/\(name).app" }
}

/// One build to install: the zip the app downloaded, and what its release says it is.
public struct BundleInstallRequest: Sendable, Codable, Equatable {
    public var zipPath: String
    public var bundleID: String
    /// The zip's SHA-256 as its release lists it (64 hex digits, either case).
    public var sha256: String
    /// The app's name: it goes to `<applications>/<name>.app`.
    public var name: String

    public init(zipPath: String, bundleID: String, sha256: String, name: String) {
        self.zipPath = zipPath
        self.bundleID = bundleID
        self.sha256 = sha256
        self.name = name
    }
}

/// A build put in place.
public struct InstallResult: Sendable, Codable, Equatable {
    /// Where it is: `<applications>/<name>.app`.
    public var destination: String
    /// The copy it replaced, kept by the service until `discard` or `restore`: an opaque id (nil: nothing was there).
    public var backup: String?
    /// The SHA-256 of the installed app's main executable: what `restore` checks is still in place.
    public var executableSHA256: String

    public init(destination: String, backup: String?, executableSHA256: String) {
        self.destination = destination
        self.backup = backup
        self.executableSHA256 = executableSHA256
    }
}

/// What the service keeps beside a backup: where it was taken from, and what replaced it, so `restore` puts it back
/// only there and only over that build.
public struct BackupManifest: Sendable, Codable, Equatable {
    public var bundleID: String
    public var name: String
    public var destination: String
    /// The build that replaced it: its main executable's SHA-256.
    public var installedExecutableSHA256: String

    public init(bundleID: String, name: String, destination: String, installedExecutableSHA256: String) {
        self.bundleID = bundleID
        self.name = name
        self.destination = destination
        self.installedExecutableSHA256 = installedExecutableSHA256
    }
}

/// Why an install, a restore or a watch was refused: a stable code to phrase it by, and a plain reason.
public struct InstallRefusal: Error, Sendable, Codable, Equatable, CustomStringConvertible {
    public enum Code: String, Sendable, Codable {
        case notInstallable, badName, noFile, outsideFolders, unreadable, badDigest, digestDiffers, tooLarge
        case unpackFailed, unpackTimedOut, notOneApp, notAFolder, wrongBundleID, badSignature, downgrade, notInstalled
        case destinationTaken, quarantine, swapFailed
        case backupMissing, backupInvalid, installedChanged
        case watchInProgress, watchFailed, noWatches
        case badRequest, unreachable
        /// A code this build doesn't know (a newer service's).
        case unknown

        public init(from decoder: Decoder) throws {
            self = Code(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }

    public var code: Code
    public var reason: String

    public init(_ code: Code, _ reason: String) {
        self.code = code
        self.reason = reason
    }

    public var description: String { reason }
}
