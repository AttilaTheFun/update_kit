import Foundation

/// The watcher's rules (docs/Installing.md, "Staying up"), run in the detached process the service starts:
///
/// 1. the lock taken (`WatchLock`, the policy's);
/// 2. the asking app's exit waited for (up to `quitSeconds`: an app that doesn't quit fails the watch), then the new
///    build opened;
/// 3. its process found running the destination's main executable (within `startSeconds`);
/// 4. with a health URL, an answer from it (within `firstAnswerSeconds`, from the watched process's listener where
///    that's asked and can be seen) while that process runs;
/// 5. that process still running `seconds` later.
///
/// Then the backup is discarded and the note says `stayedUp`. Short of it, the new build's process (if any) is sent
/// SIGTERM, then SIGKILL if it hasn't ended five seconds later, the backup restored (BundleInstall.restore: refused if
/// the build in place has changed since) and opened again, and the note says `restored` with why, or `restoreFailed`
/// with both whys. The lock is released last.
public enum StayUpWatcher {
    /// How often it looks, in seconds.
    static let interval: TimeInterval = 1

    /// The watch as the service carries it out: refused unless the policy has a watch's lock and note, the watch's app
    /// is one of the policy's at its destination, its backup (if any) one the service keeps, and its health URL (if
    /// any) on this Mac.
    public static func checked(_ watch: StayUpWatch, policy: InstallPolicy, files: any BundleInstallSystem) -> Result<StayUpWatch, InstallRefusal> {
        guard policy.watchLockPath != nil, policy.watchNotePath != nil else {
            return .failure(InstallRefusal(.noWatches, "This installer has no place for a watch's lock and note, so it watches nothing."))
        }
        guard let name = BundleInstall.destinationName(watch.install.destination, policy: policy), policy.installs(watch.bundleID, name: name),
              watch.install.destination == policy.destination(name: name) else {
            return .failure(InstallRefusal(.notInstallable, "This installer doesn't watch \(watch.install.destination) (\(watch.bundleID))."))
        }
        if let backup = watch.install.backup, BundleInstall.backupFolder(backup, system: files) == nil {
            return .failure(InstallRefusal(.backupMissing, "The watch's earlier build isn't kept by this installer."))
        }
        if let url = watch.healthURL, !["127.0.0.1", "localhost", "::1", "[::1]"].contains(url.host ?? "") || !["http", "https"].contains(url.scheme ?? "") {
            return .failure(InstallRefusal(.badRequest, "A watch's health URL must be on this Mac (loopback)."))
        }
        guard watch.quittingPID > 1 else { return .failure(InstallRefusal(.badRequest, "A watch needs the asking app's process.")) }
        return .success(watch)
    }

    @discardableResult
    public static func run(_ watch: StayUpWatch, policy: InstallPolicy, system: any WatchSystem) -> WatchNote {
        guard let lockPath = policy.watchLockPath, let notePath = policy.watchNotePath else {
            return WatchNote(outcome: .restoreFailed, reason: "This installer has no place for a watch's lock and note.",
                             bundleID: watch.bundleID, executableSHA256: watch.install.executableSHA256, at: system.now())
        }
        do { try WatchLock.take(lockPath, ownFolder: system.files.ownFolder, system: system) } catch {
            // Watched anyway: the lock only keeps two watchers from undoing each other's work.
        }
        defer { WatchLock.release(lockPath, system: system) }

        var watched: Int32?
        let failure = watchNewBuild(watch, system: system, found: { watched = $0 })
        let note: WatchNote
        if let failure {
            if let watched { end(watched, system: system) }
            note = putBack(watch, policy: policy, because: failure, system: system)
        } else {
            if let backup = watch.install.backup { BundleInstall.discard(backup: backup, system: system.files) }
            note = WatchNote(outcome: .stayedUp, reason: nil, bundleID: watch.bundleID,
                             executableSHA256: watch.install.executableSHA256, at: system.now())
        }
        try? system.write(note.json, to: notePath)
        return note
    }

    /// A process ended: SIGTERM, then SIGKILL if it's still there five seconds later, and waited for.
    static func end(_ pid: Int32, system: any WatchSystem) {
        guard system.isAlive(pid) else { return }
        system.terminate(pid)
        let killBy = system.now().addingTimeInterval(5)
        while system.isAlive(pid), system.now() < killBy { system.sleep(0.25) }
        guard system.isAlive(pid) else { return }
        system.kill(pid)
        let goneBy = system.now().addingTimeInterval(5)
        while system.isAlive(pid), system.now() < goneBy { system.sleep(0.25) }
    }

    /// Nil once the new build has stayed up, else why not.
    static func watchNewBuild(_ watch: StayUpWatch, system: any WatchSystem, found: (Int32) -> Void) -> String? {
        // The app that asked, quitting.
        let quitBy = system.now().addingTimeInterval(watch.quitSeconds)
        while system.isAlive(watch.quittingPID) {
            guard system.now() < quitBy else { return "The app didn't quit within \(Int(watch.quitSeconds)) seconds, so its update was undone." }
            system.sleep(interval)
        }

        guard let executable = system.files.infoValue("CFBundleExecutable", ofApp: watch.install.destination),
              BundleInstall.refusal(name: executable) == nil else {
            return "The new build has no main executable to open."
        }
        let executablePath = "\(watch.install.destination)/Contents/MacOS/\(executable)"
        guard system.open(app: watch.install.destination) else { return "The new build couldn't be opened." }

        // Its process.
        let startBy = system.now().addingTimeInterval(watch.startSeconds)
        var pid: Int32?
        while pid == nil {
            pid = system.pids(runningExecutable: executablePath).first
            if pid != nil { break }
            guard system.now() < startBy else { return "The new build didn't start within \(Int(watch.startSeconds)) seconds." }
            system.sleep(interval)
        }
        guard let pid else { return "The new build didn't start." }
        found(pid)

        // Its first answer, a server's.
        if let url = watch.healthURL {
            let answerBy = system.now().addingTimeInterval(watch.firstAnswerSeconds)
            while true {
                guard system.isAlive(pid) else { return "The new build quit before it answered." }
                if system.answers(url) {
                    let listeners = watch.listenerMustBeWatched ? system.listenerPIDs(of: url) : []
                    if listeners.isEmpty || listeners.contains(pid) { break }
                }
                guard system.now() < answerBy else {
                    return "The new build didn't answer within \(Int(watch.firstAnswerSeconds)) seconds."
                }
                system.sleep(interval)
            }
        }

        // Staying up.
        let upUntil = system.now().addingTimeInterval(watch.seconds)
        while system.now() < upUntil {
            guard system.isAlive(pid) else { return "The new build quit within \(Int(watch.seconds)) seconds of starting." }
            system.sleep(interval)
        }
        return system.isAlive(pid) ? nil : "The new build quit within \(Int(watch.seconds)) seconds of starting."
    }

    /// The backup restored and opened, or why it couldn't be.
    static func putBack(_ watch: StayUpWatch, policy: InstallPolicy, because failure: String, system: any WatchSystem) -> WatchNote {
        func note(_ outcome: WatchNote.Outcome, _ reason: String) -> WatchNote {
            WatchNote(outcome: outcome, reason: reason, bundleID: watch.bundleID, executableSHA256: watch.install.executableSHA256,
                      at: system.now())
        }
        guard let backup = watch.install.backup else {
            return note(.restoreFailed, "\(failure) There was no earlier build to put back.")
        }
        switch BundleInstall.restore(backup: backup, policy: policy, system: system.files) {
        case .success:
            _ = system.open(app: watch.install.destination)
            return note(.restored, failure)
        case .failure(let refusal):
            return note(.restoreFailed, "\(failure) The earlier build couldn't be put back: \(refusal.reason)")
        }
    }
}
