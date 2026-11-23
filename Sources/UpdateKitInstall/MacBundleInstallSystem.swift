#if os(macOS)
import CryptoKit
import Darwin
import Foundation
import Security

/// BundleInstall's rules carried out on this Mac, by an installer service outside the App Sandbox, so nothing the new
/// build is made of was written by a sandboxed process: the copying copyfile's (data alone), the unpacking ditto's with
/// --noqtn, the checks SecStaticCode's, the swap renamex_np's.
///
/// The signature (the policy's `signing`): valid (strict, every architecture, nested code) and meeting a requirement
/// that always names Apple's anchor and the service's own team (`certificate leaf[subject.OU]`), so a self-signed
/// certificate claiming the team doesn't pass; by default also the team's Developer ID Application certificate and
/// notarization, refused when notarization can't be checked. A service with no team (an ad hoc test build) installs
/// only with `adHocForTests`, which only a debug build of this library honours.
public struct MacBundleInstallSystem: BundleInstallSystem {
    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    public let ownFolder: String

    /// `ownFolder`: by default this service's own, by its bundle id, in the user's temporary folder (the service isn't
    /// sandboxed): never another service's.
    public init(ownFolder: String? = nil) {
        let service = Bundle.main.bundleIdentifier ?? "service-\(getuid())"
        self.ownFolder = ownFolder ?? (NSTemporaryDirectory() as NSString).appendingPathComponent("UpdateKitInstall-\(service)")
    }

    /// The app around this process's bundle, when it's a service inside one.
    public static func enclosingApp() -> URL? {
        let host = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return host.pathExtension == "app" ? host : nil
    }

    public func resolvingLinks(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    public func isFile(_ path: String) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.type] as? FileAttributeType == .typeRegular
    }

    public func isRealFolder(_ path: String) -> Bool {
        var status = stat()
        return lstat(path, &status) == 0 && (status.st_mode & S_IFMT) == S_IFDIR
    }

    public func exists(_ path: String) -> Bool {
        var status = stat()
        return lstat(path, &status) == 0
    }

    public func modified(_ path: String) -> Date? {
        var status = stat()
        guard lstat(path, &status) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(status.st_mtimespec.tv_sec))
    }

    public func sha256(ofFile path: String) throws -> String {
        guard let handle = FileHandle(forReadingAtPath: path) else { throw Failure(description: "it can't be opened") }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public func createFolder(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }

    public func makeFolder() throws -> String {
        let manager = FileManager.default
        try manager.createDirectory(atPath: ownFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let folder = "\(ownFolder)/\(UUID().uuidString)"
        try manager.createDirectory(atPath: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return folder
    }

    public func copy(zip: String, into folder: String, within folders: [String], maxBytes: Int) throws -> String {
        // One opening of it, never through a link; then what it is, how big, and where the file opened really is.
        let source = open(zip, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard source >= 0 else { throw Failure(description: Self.errorText()) }
        defer { close(source) }
        var status = stat()
        guard fstat(source, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG else {
            throw InstallRefusal(.noFile, "The build's file isn't a plain file.")
        }
        guard Int(status.st_size) <= maxBytes else { throw InstallRefusal(.tooLarge, "The build's file is larger than this installer takes.") }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(source, F_GETPATH, &buffer) != -1, case let opened = Self.path(of: buffer),
              folders.contains(where: { BundleInstall.isInside(opened, $0) }) else {
            throw InstallRefusal(.outsideFolders, "The build's file isn't in a folder this installer takes builds from.")
        }
        let copy = "\(folder)/build.zip"
        let target = open(copy, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard target >= 0 else { throw Failure(description: Self.errorText()) }
        defer { close(target) }
        // The data alone (no extended attribute, so no quarantine either).
        guard fcopyfile(source, target, nil, copyfile_flags_t(COPYFILE_DATA)) == 0 else { throw Failure(description: Self.errorText()) }
        return copy
    }

    public func size(of path: String) -> Int {
        var total = 0
        guard let walk = FileManager.default.enumerator(atPath: path) else { return 0 }
        for case let relative as String in walk {
            var status = stat()
            if lstat("\(path)/\(relative)", &status) == 0 { total += Int(status.st_size) }
        }
        return total
    }

    public func read(_ path: String) -> Data? {
        let file = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard file >= 0 else { return nil }
        return FileHandle(fileDescriptor: file, closeOnDealloc: true).readDataToEndOfFile()
    }

    public func write(_ data: Data, to path: String) throws {
        let file = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw Failure(description: Self.errorText()) }
        let handle = FileHandle(fileDescriptor: file, closeOnDealloc: true)
        try handle.write(contentsOf: data)
    }

    /// What errno says.
    static func errorText(_ code: Int32 = errno) -> String { String(cString: strerror(code)) }

    public func unpack(zip: String, into folder: String, timeLimit: TimeInterval) throws {
        let result = Self.run("/usr/bin/ditto", ["-x", "-k", "--noqtn", zip, folder], timeLimit: timeLimit)
        guard !result.timedOut else {
            throw InstallRefusal(.unpackTimedOut, "Unpacking the build took longer than \(Int(timeLimit)) seconds, so it was stopped.")
        }
        guard result.status == 0 else {
            throw Failure(description: "ditto exited \(result.status): \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    public func entries(of folder: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
    }

    public func infoValue(_ key: String, ofApp path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: "\(path)/Contents/Info.plist"),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return plist[key] as? String
    }

    public func signatureRefusal(ofApp path: String, signing: InstallPolicy.Signing) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code else {
            return "The build's signature cannot be read."
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        let status = SecStaticCodeCheckValidity(code, flags, nil)
        guard status == errSecSuccess else { return "The build's signature is not valid (\(status))." }
        switch (Self.ownSigning, signing) {
        case (.unreadable, _):
            return "The installer can't read its own signature, so it installs nothing."
        case (.adHoc, .adHocForTests):
            #if DEBUG
            // A test build of the service, in a test VM: ad hoc builds alone.
            return Self.teamID(of: code) == nil ? nil : "This installer is an ad hoc test build: it installs only builds with no team."
            #else
            return "Ad hoc builds are installed only by a debug build of the installer."
            #endif
        case (.adHoc, _):
            return "The installer has no team of its own, so it installs nothing."
        case (.team, .adHocForTests):
            return "This installer is its team's: it installs no ad hoc build."
        case (.team(let own), let signing):
            guard let requirement = Self.requirement(team: own, developerID: signing == .developerID) else {
                return "The installer couldn't make its signature requirement."
            }
            guard SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess else {
                return signing == .developerID ? "The build isn't signed with its team's Developer ID and notarized."
                    : "The build isn't signed by this installer's team."
            }
            return nil
        }
    }

    public func removeQuarantine(under path: String) throws {
        var paths = [path]
        // Every file, folder and link in the bundle, never following a link out of it.
        if let walk = FileManager.default.enumerator(atPath: path) {
            for case let relative as String in walk { paths.append("\(path)/\(relative)") }
        }
        for item in paths where removexattr(item, "com.apple.quarantine", XATTR_NOFOLLOW) != 0 && errno != ENOATTR {
            throw Failure(description: "\(item): \(Self.errorText())")
        }
    }

    public func swap(_ new: String, into destination: String) throws -> String? {
        func failure(_ code: Int32) -> Failure { Failure(description: Self.errorText(code)) }
        guard exists(destination) else {
            // Never over anything that appeared meanwhile.
            if renamex_np(new, destination, UInt32(RENAME_EXCL)) == 0 { return nil }
            guard errno == EXDEV else { throw failure(errno) }
            try FileManager.default.copyItem(atPath: new, toPath: destination)
            return nil
        }
        if renamex_np(new, destination, UInt32(RENAME_SWAP)) == 0 { return new }
        guard errno == EXDEV else { throw failure(errno) }
        // On another volume than the service's folder: copied beside it first, then swapped, and what it replaced moved
        // back into the service's folder, where its backup is kept.
        let name = ((destination as NSString).lastPathComponent as NSString).deletingPathExtension
        let beside = ((destination as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent(".\(name)-new-\(UUID().uuidString).app")
        try FileManager.default.copyItem(atPath: new, toPath: beside)
        guard renamex_np(beside, destination, UInt32(RENAME_SWAP)) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(atPath: beside)
            throw failure(code)
        }
        // `beside` is the replaced copy now; `new` is the unpacked build, no longer needed: the backup takes its place.
        try? FileManager.default.removeItem(atPath: new)
        do {
            try FileManager.default.copyItem(atPath: beside, toPath: new)
            try? FileManager.default.removeItem(atPath: beside)
            return new
        } catch {
            return beside
        }
    }

    static let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

    public func register(app path: String) { _ = Self.run(Self.lsregister, ["-f", path], timeLimit: 60) }

    public func unregister(app path: String) { _ = Self.run(Self.lsregister, ["-u", path], timeLimit: 60) }

    public func isInUse(_ path: String) -> Bool {
        Self.runningExecutables().contains { $0.hasPrefix(path + "/") }
    }

    public func remove(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    /// Every running process's executable's path.
    static func runningExecutables() -> [String] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        // Room for processes started meanwhile.
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let found = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard found > 0 else { return [] }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        var paths: [String] = []
        for pid in pids.prefix(Int(found)) where pid > 0 {
            if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 { paths.append(path(of: buffer)) }
        }
        return paths
    }

    /// A C string's bytes, up to its NUL, as a path.
    static func path(of buffer: [CChar]) -> String {
        String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// A program's status and its output (standard output and error together). With a time limit, a program still
    /// running at its end is stopped (SIGTERM, then SIGKILL five seconds later), and `timedOut` says so.
    static func run(_ path: String, _ arguments: [String], timeLimit: TimeInterval? = nil)
        -> (status: Int32, output: String, timedOut: Bool) {
        guard FileManager.default.isExecutableFile(atPath: path) else { return (-1, "\(path) isn't there", false) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, "\(error)", false) }
        let run = RunState()
        if let timeLimit {
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + timeLimit) {
                guard run.stop() else { return }
                kill(pid, SIGTERM)
                DispatchQueue.global().asyncAfter(deadline: .now() + 5) { if !run.finished { kill(pid, SIGKILL) } }
            }
        }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        run.finish()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self), run.stopped)
    }

    /// A run's state for its time limit, which is checked on another thread than the one waiting: whether the program
    /// has finished (then nothing is signalled, its process id possibly another's by now), and whether the limit
    /// stopped it.
    final class RunState: @unchecked Sendable {
        private let lock = NSLock()
        private var isFinished = false
        private var wasStopped = false

        /// Marks it stopped by the limit: false (and nothing marked) once it has finished.
        func stop() -> Bool {
            lock.withLock {
                guard !isFinished else { return false }
                wasStopped = true
                return true
            }
        }

        func finish() { lock.withLock { isFinished = true } }
        var finished: Bool { lock.withLock { isFinished } }
        var stopped: Bool { lock.withLock { wasStopped } }
    }

    /// How this service is signed: by a team (every published build), ad hoc (a test build), or unreadably (then it
    /// installs nothing).
    enum Signing {
        case team(String)
        case adHoc
        case unreadable
    }

    static let ownSigning: Signing = {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return .unreadable }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return .unreadable }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any] else { return .unreadable }
        guard let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty else { return .adHoc }
        return .team(team)
    }()

    static func teamID(of code: SecStaticCode) -> String? {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any], let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String,
              !team.isEmpty else { return nil }
        return team
    }

    /// The requirement a build meets: Apple's chain and a certificate of `team`'s; with `developerID`, a Developer ID
    /// Application certificate (its marker extension) and a notarization ticket too.
    static func requirement(team: String, developerID: Bool) -> SecRequirement? {
        var text = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
        if developerID { text += " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and notarized" }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess else { return nil }
        return requirement
    }

    /// This service's team, nil for an ad hoc build (or one whose signature can't be read).
    public static var ownTeam: String? {
        if case .team(let team) = ownSigning { return team }
        return nil
    }
}
#endif
