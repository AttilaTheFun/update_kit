import Foundation

/// The watch's lock: a file holding one line, `<pid> <started-epoch-seconds>`, that counts only while that pid is
/// alive, so a stale file never blocks. A new watcher sends SIGTERM to a live holder (only one that is a watcher, its
/// executable in the service's own folder, so a line written by anyone else never has a process signalled) and waits a
/// second before writing its own line; a watcher removes the file at its end only if the line is still its own. (The
/// same lock as an app's own watcher may already take, so theirs and this one are interchangeable.)
public enum WatchLock {
    /// The live holder: its pid and when it started; nil when nobody (or a dead process) holds it.
    public static func holder(_ path: String, system: any WatchSystem) -> (pid: Int32, started: Date)? {
        guard let line = system.read(path) else { return nil }
        let fields = line.split(whereSeparator: { $0 == " " || $0 == "\n" })
        guard fields.count >= 2, let pid = Int32(fields[0]), pid > 1, let started = TimeInterval(fields[1]),
              system.isAlive(pid) else { return nil }
        return (pid, Date(timeIntervalSince1970: started))
    }

    /// The lock taken by this process: a live holder other than it, a watcher of this service's (in `ownFolder`),
    /// sent SIGTERM first.
    public static func take(_ path: String, ownFolder: String, system: any WatchSystem) throws {
        if let holder = holder(path, system: system), holder.pid != system.ownPID,
           let executable = system.executablePath(of: holder.pid), BundleInstall.isInside(executable, ownFolder) {
            system.terminate(holder.pid)
            system.sleep(1)
        }
        try system.write(line(system), to: path)
    }

    /// The lock given up, if it's still this process's.
    public static func release(_ path: String, system: any WatchSystem) {
        guard let line = system.read(path), line.split(separator: " ").first.flatMap({ Int32($0) }) == system.ownPID else { return }
        system.remove(path)
    }

    static func line(_ system: any WatchSystem) -> String {
        "\(system.ownPID) \(Int(system.now().timeIntervalSince1970))\n"
    }
}
