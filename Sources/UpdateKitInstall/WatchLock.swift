import Foundation

/// The watch's lock: a file holding one line, `<pid> <started-epoch-seconds>`, that counts only while that pid is
/// alive, so a stale file never blocks. A new watcher sends SIGTERM to a live holder before writing its own line, and a
/// watcher removes the file at its end only if the line is still its own. (The same lock as an app's own watcher may
/// already take, so theirs and this one are interchangeable.)
public enum WatchLock {
    /// The live holder: its pid and when it started; nil when nobody (or a dead process) holds it.
    public static func holder(_ path: String, system: any WatchSystem) -> (pid: Int32, started: Date)? {
        guard let line = system.read(path) else { return nil }
        let fields = line.split(whereSeparator: { $0 == " " || $0 == "\n" })
        guard fields.count >= 2, let pid = Int32(fields[0]), pid > 0, let started = TimeInterval(fields[1]),
              system.isAlive(pid) else { return nil }
        return (pid, Date(timeIntervalSince1970: started))
    }

    /// The lock taken by this process: a live holder other than it sent SIGTERM first.
    public static func take(_ path: String, system: any WatchSystem) throws {
        if let holder = holder(path, system: system), holder.pid != system.ownPID { system.terminate(holder.pid) }
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
