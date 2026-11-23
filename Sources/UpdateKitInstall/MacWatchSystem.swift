#if os(macOS)
import Darwin
import Foundation

/// The watcher's Mac: kill(2)'s signals, LaunchServices' `open`, libproc's process list, URLSession for the health
/// URL and lsof for its listener.
public struct MacWatchSystem: WatchSystem {
    public let files: any BundleInstallSystem

    public init(files: any BundleInstallSystem = MacBundleInstallSystem()) {
        self.files = files
    }

    public func now() -> Date { Date() }
    public func sleep(_ seconds: TimeInterval) { Thread.sleep(forTimeInterval: seconds) }
    public var ownPID: Int32 { getpid() }

    public func isAlive(_ pid: Int32) -> Bool { pid > 1 && (Darwin.kill(pid, 0) == 0 || errno == EPERM) }
    public func terminate(_ pid: Int32) { if pid > 1 { Darwin.kill(pid, SIGTERM) } }
    public func kill(_ pid: Int32) { if pid > 1 { Darwin.kill(pid, SIGKILL) } }

    public func executablePath(of pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return MacBundleInstallSystem.path(of: buffer)
    }

    public func read(_ path: String) -> String? { files.read(path).map { String(decoding: $0, as: UTF8.self) } }

    /// Written whole, through its folder opened without following a link: into a new file of its own beside it, never
    /// followed either, then renamed over it in that folder in one step. A link the app put at either sends nothing
    /// anywhere, and a reader never sees half of it.
    public func write(_ text: String, to path: String) throws {
        func failure() -> MacBundleInstallSystem.Failure { MacBundleInstallSystem.Failure(description: MacBundleInstallSystem.errorText()) }
        let folder = Darwin.open((path as NSString).deletingLastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard folder >= 0 else { throw failure() }
        defer { close(folder) }
        let name = (path as NSString).lastPathComponent, temporary = ".\(name).\(UUID().uuidString)"
        let file = openat(folder, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw failure() }
        do {
            try FileHandle(fileDescriptor: file, closeOnDealloc: true).write(contentsOf: Data(text.utf8))
        } catch {
            unlinkat(folder, temporary, 0)
            throw error
        }
        guard renameat(folder, temporary, folder, name) == 0 else {
            let error = failure()
            unlinkat(folder, temporary, 0)
            throw error
        }
    }

    public func remove(_ path: String) { try? FileManager.default.removeItem(atPath: path) }

    public func open(app path: String) -> Bool {
        MacBundleInstallSystem.run("/usr/bin/open", [path], timeLimit: 60).status == 0
    }

    public func pids(runningExecutable path: String) -> [Int32] {
        let wanted = files.resolvingLinks(path) ?? path
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let found = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard found > 0 else { return [] }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        return pids.prefix(Int(found)).filter { pid in
            pid > 0 && proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 && MacBundleInstallSystem.path(of: buffer) == wanted
        }
    }

    public func answers(_ url: URL) -> Bool {
        let answered = Answered()
        let done = DispatchSemaphore(value: 0)
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        let task = URLSession.shared.dataTask(with: request) { _, response, _ in
            if response is HTTPURLResponse { answered.set() }
            done.signal()
        }
        task.resume()
        if done.wait(timeout: .now() + 10) == .timedOut { task.cancel() }
        return answered.value
    }

    public func listenerPIDs(of url: URL) -> [Int32] {
        guard let port = url.port ?? (url.scheme == "https" ? 443 : url.scheme == "http" ? 80 : nil) else { return [] }
        let result = MacBundleInstallSystem.run("/usr/sbin/lsof", ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"], timeLimit: 10)
        guard result.status == 0 else { return [] }
        return result.output.split(whereSeparator: \.isNewline).compactMap { Int32($0) }
    }

    /// Whether a request was answered, set on URLSession's queue.
    final class Answered: @unchecked Sendable {
        private let lock = NSLock()
        private var answered = false
        func set() { lock.withLock { answered = true } }
        var value: Bool { lock.withLock { answered } }
    }
}

/// The watcher started by the service, outliving it and the app: a copy of the service's bundle (so the build in place
/// can change under it), run by a one-shot launchd job of the user's (`AbandonProcessGroup`), in watch mode.
public enum StayUpWatchLauncher {
    /// What the service is run with to watch: `<executable> --update-kit-stay-up-watch <watch.json> <label>`.
    public static let argument = "--update-kit-stay-up-watch"

    /// A watch's launchd label: the app's bundle id, then this, then the watch's folder's name.
    static let labelInfix = ".update-kit.stay-up-watch."

    /// For the service's `main`, first (`UpdateKitInstallService.main` calls it): when it's run as a watcher, the watch
    /// carried out with the service's own policy, and the process ended (its job removed); otherwise nothing. Only a
    /// watch file in a folder of the service's own, with the label its start gave, is taken, and the watch is checked
    /// again as the service checked it.
    public static func runIfAsked(policy: InstallPolicy, files: MacBundleInstallSystem = MacBundleInstallSystem(),
                                  arguments: [String] = CommandLine.arguments) {
        guard arguments.count == 4, arguments[1] == argument else { return }
        defer { exit(0) }
        let file = arguments[2], label = arguments[3]
        guard let own = files.resolvingLinks(files.ownFolder), let resolved = files.resolvingLinks(file),
              (resolved as NSString).lastPathComponent == "watch.json", case let folder = (resolved as NSString).deletingLastPathComponent,
              (folder as NSString).deletingLastPathComponent == own, let data = files.read(resolved),
              let watch = try? JSONDecoder().decode(StayUpWatch.self, from: data),
              label == watch.bundleID + labelInfix + (folder as NSString).lastPathComponent else { return }
        if case .success(let checked) = StayUpWatcher.checked(watch, policy: policy, files: files) {
            StayUpWatcher.run(checked, policy: policy, system: MacWatchSystem(files: files))
        }
        // The copy it ran from, and its job, gone (bootout ends this process too, so it's last).
        files.remove(folder)
        _ = MacBundleInstallSystem.run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"], timeLimit: 10)
    }

    /// The watch started, the service's own bundle (`service`, by default this process's) copied into a folder of its
    /// own: refused while another watcher holds the policy's lock.
    public static func start(_ watch: StayUpWatch, policy: InstallPolicy, files: MacBundleInstallSystem = MacBundleInstallSystem(),
                             service: URL = Bundle.main.bundleURL) -> Result<Void, InstallRefusal> {
        guard let lockPath = policy.watchLockPath else {
            return .failure(InstallRefusal(.noWatches, "This installer has no place for a watch's lock, so it watches nothing."))
        }
        let system = MacWatchSystem(files: files)
        if let holder = WatchLock.holder(lockPath, system: system) {
            return .failure(InstallRefusal(.watchInProgress, "Another update is being watched (since \(holder.started)): try again later."))
        }
        // Held at once, by the service, until the watcher takes it over (it never signals the service, which isn't one
        // of its copies): no install goes ahead in between.
        do { try WatchLock.take(lockPath, ownFolder: files.ownFolder, system: system) } catch {
            return .failure(InstallRefusal(.watchFailed, "The watch's lock couldn't be taken: \(error)"))
        }
        var made: String?
        do {
            let folder = try files.makeFolder()
            made = folder
            let copy = "\(folder)/\(service.lastPathComponent)"
            try FileManager.default.copyItem(atPath: service.path, toPath: copy)
            guard let executable = Bundle(path: copy)?.executablePath else {
                files.remove(folder)
                return .failure(InstallRefusal(.watchFailed, "The installer's own bundle has no executable to watch with."))
            }
            let file = "\(folder)/watch.json"
            try files.write(try JSONEncoder().encode(watch), to: file)
            let label = watch.bundleID + labelInfix + (folder as NSString).lastPathComponent
            let job: [String: Any] = [
                "Label": label,
                "ProgramArguments": [executable, argument, file, label],
                "RunAtLoad": true,
                "AbandonProcessGroup": true,
                "StandardOutPath": "/dev/null",
                "StandardErrorPath": "/dev/null",
            ]
            let plist = "\(folder)/job.plist"
            try files.write(try PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0), to: plist)
            let result = MacBundleInstallSystem.run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", plist], timeLimit: 30)
            guard result.status == 0 else {
                // A job half-loaded goes too.
                _ = MacBundleInstallSystem.run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"], timeLimit: 10)
                files.remove(folder)
                WatchLock.release(lockPath, system: system)
                return .failure(InstallRefusal(.watchFailed, "The watcher couldn't be started: launchctl exited \(result.status)."))
            }
            return .success(())
        } catch {
            if let made { files.remove(made) }
            WatchLock.release(lockPath, system: system)
            return .failure(InstallRefusal(.watchFailed, "The watcher couldn't be started: \(error)"))
        }
    }
}
#endif
