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

    public func isAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 || errno == EPERM }
    public func terminate(_ pid: Int32) { kill(pid, SIGTERM) }

    public func read(_ path: String) -> String? { try? String(contentsOfFile: path, encoding: .utf8) }

    public func write(_ text: String, to path: String) throws {
        try Data(text.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
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
            pid > 0 && proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 && String(cString: buffer) == wanted
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

    public func listenerPID(of url: URL) -> Int32? {
        guard let port = url.port ?? (url.scheme == "https" ? 443 : url.scheme == "http" ? 80 : nil) else { return nil }
        let result = MacBundleInstallSystem.run("/usr/sbin/lsof", ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"], timeLimit: 10)
        guard result.status == 0 else { return nil }
        return result.output.split(whereSeparator: \.isNewline).first.flatMap { Int32($0) }
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

    /// For the service's `main`, first: when it's run as a watcher, the watch carried out and the process ended (its
    /// launchd job removed); otherwise nothing.
    public static func runIfAsked(arguments: [String] = CommandLine.arguments) {
        guard arguments.count >= 4, arguments[1] == argument else { return }
        let file = arguments[2], label = arguments[3]
        let decoder = JSONDecoder()
        if let data = FileManager.default.contents(atPath: file), let watch = try? decoder.decode(StayUpWatch.self, from: data) {
            StayUpWatcher.run(watch, system: MacWatchSystem())
        }
        // The copy it ran from, and its job, gone (bootout ends this process too, so it's last).
        let folder = (file as NSString).deletingLastPathComponent
        try? FileManager.default.removeItem(atPath: folder)
        _ = MacBundleInstallSystem.run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"], timeLimit: 10)
        exit(0)
    }

    /// The watch started, the service's own bundle (`service`, by default this process's) copied into its folder:
    /// refused while another watcher holds the lock.
    public static func start(_ watch: StayUpWatch, files: MacBundleInstallSystem = MacBundleInstallSystem(),
                             service: URL = Bundle.main.bundleURL) -> Result<Void, InstallRefusal> {
        let system = MacWatchSystem(files: files)
        if let holder = WatchLock.holder(watch.lockPath, system: system) {
            return .failure(InstallRefusal(.watchInProgress, "Another update is being watched (since \(holder.started)): try again later."))
        }
        do {
            let folder = try files.makeFolder()
            let copy = "\(folder)/\(service.lastPathComponent)"
            try FileManager.default.copyItem(atPath: service.path, toPath: copy)
            guard let executable = Bundle(path: copy)?.executablePath else {
                return .failure(InstallRefusal(.watchFailed, "The installer's own bundle has no executable to watch with."))
            }
            let file = "\(folder)/watch.json"
            try JSONEncoder().encode(watch).write(to: URL(fileURLWithPath: file), options: .atomic)
            let label = "\(watch.bundleID).update-kit.stay-up-watch.\((folder as NSString).lastPathComponent)"
            let job: [String: Any] = [
                "Label": label,
                "ProgramArguments": [executable, argument, file, label],
                "RunAtLoad": true,
                "AbandonProcessGroup": true,
                "StandardOutPath": "/dev/null",
                "StandardErrorPath": "/dev/null",
            ]
            let plist = "\(folder)/job.plist"
            try PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0)
                .write(to: URL(fileURLWithPath: plist), options: .atomic)
            let result = MacBundleInstallSystem.run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", plist], timeLimit: 30)
            guard result.status == 0 else {
                files.remove(folder)
                return .failure(InstallRefusal(.watchFailed, "The watcher couldn't be started: launchctl exited \(result.status)."))
            }
            return .success(())
        } catch {
            return .failure(InstallRefusal(.watchFailed, "The watcher couldn't be started: \(error)"))
        }
    }
}
#endif
