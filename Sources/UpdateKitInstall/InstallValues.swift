import Foundation

/// What an installer service takes builds of, and from where: the caller's, checked by the service on every call
/// (docs/Installing.md).
public struct InstallPolicy: Sendable, Codable, Equatable {
    /// The bundle ids it installs: this prefix, then at least one more component (`com.example.App` takes
    /// `com.example.App` and `com.example.App.Helper`, never `com.example.Application`).
    public var bundleIDPrefix: String
    /// The folders a zip may be in, each with its links resolved (the app's sandbox container, an app group's
    /// container): a zip anywhere else, or reached through a link out of them, is refused.
    public var zipFolders: [String]
    /// Where apps go.
    public var applications: String
    /// How long unpacking may take, in seconds, before ditto is stopped and the install refused.
    public var unpackTimeLimit: TimeInterval
    /// How long a replaced copy nobody discarded or restored (and nothing runs from) is kept before a later install
    /// sweeps it, in seconds.
    public var backupLifetime: TimeInterval
    /// What an app's earlier bundle ids added to its own (`.Beta`, say): a copy at the app's name with one of them is
    /// the same app, which an install replaces.
    public var earlierIDSuffixes: [String]
    /// The folders a watch's lock and note may be in (with the zip folders), links resolved: the unsandboxed service
    /// writes them, so never where the app alone chose.
    public var watchFolders: [String]

    public init(bundleIDPrefix: String, zipFolders: [String], applications: String = "/Applications",
                unpackTimeLimit: TimeInterval = 300, backupLifetime: TimeInterval = 86_400, earlierIDSuffixes: [String] = [],
                watchFolders: [String] = []) {
        self.bundleIDPrefix = bundleIDPrefix
        self.zipFolders = zipFolders
        self.applications = applications
        self.unpackTimeLimit = unpackTimeLimit
        self.backupLifetime = backupLifetime
        self.earlierIDSuffixes = earlierIDSuffixes
        self.watchFolders = watchFolders
    }

    /// Whether `other` is `bundleID`'s app: the same id, or one of its earlier ones.
    public func isSameApp(_ other: String, as bundleID: String) -> Bool {
        other == bundleID || earlierIDSuffixes.contains { bundleID + $0 == other }
    }

    /// Where the app named `name` goes.
    public func destination(name: String) -> String { "\(applications)/\(name).app" }

    /// Whether `bundleID` is the prefix's: the prefix itself, or the prefix, a dot and more, of only the characters a
    /// bundle id has (letters, digits, `.` and `-`).
    public func installs(_ bundleID: String) -> Bool {
        let prefix = bundleIDPrefix.hasSuffix(".") ? String(bundleIDPrefix.dropLast()) : bundleIDPrefix
        guard !prefix.isEmpty, !bundleID.hasSuffix("."), !bundleID.contains(".."),
              bundleID.allSatisfy({ ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "." || $0 == "-" }) else { return false }
        return bundleID == prefix || bundleID.hasPrefix(prefix + ".")
    }
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
    /// The copy it replaced, kept in the service's own folder until `discard` or `restore` (nil: nothing was there).
    public var backup: String?
    /// The SHA-256 of the installed app's main executable: what `restore` checks is still in place.
    public var executableSHA256: String

    public init(destination: String, backup: String?, executableSHA256: String) {
        self.destination = destination
        self.backup = backup
        self.executableSHA256 = executableSHA256
    }
}

/// Why an install, a restore or a watch was refused: a stable code to phrase it by, and a plain reason.
public struct InstallRefusal: Error, Sendable, Codable, Equatable, CustomStringConvertible {
    public enum Code: String, Sendable, Codable {
        case notInstallable, badName, noFile, outsideFolders, unreadable, digestDiffers, unpackFailed, unpackTimedOut
        case notOneApp, wrongBundleID, badSignature, destinationTaken, quarantine, swapFailed
        case backupMissing, backupInvalid, installedChanged, watchInProgress, watchFailed
    }

    public var code: Code
    public var reason: String

    public init(_ code: Code, _ reason: String) {
        self.code = code
        self.reason = reason
    }

    public var description: String { reason }
}
