import Foundation

/// The watcher's rules (docs/Installing.md, "Staying up"), run in the detached process the service starts:
///
/// 1. the lock taken (`WatchLock`);
/// 2. the asking app's exit waited for (up to `quitSeconds`), then the new build opened;
/// 3. its process found running the destination's main executable (within `startSeconds`);
/// 4. with a health URL, an answer from it (within `firstAnswerSeconds`, from the watched process's listener where
///    that's asked and can be seen) while that process runs;
/// 5. that process still running `seconds` later.
///
/// Then the backup is discarded and the note says `stayedUp`. Short of it, the new build's process (if any) is sent
/// SIGTERM, the backup restored (BundleInstall.restore: refused if the build in place has changed since) and opened
/// again, and the note says `restored` with why, or `restoreFailed` with both whys. The lock is released last.
public enum StayUpWatcher {
    /// How often it looks, in seconds.
    static let interval: TimeInterval = 1

    /// The watch as the service carries it out: its policy the service's own (whatever the app sent), and refused
    /// unless its lock and note are in the policy's folders (their folders resolved: the files may not exist yet), its
    /// bundle id the policy's, and its destination an app's place in the applications folder.
    public static func checked(_ watch: StayUpWatch, policy: InstallPolicy, files: any BundleInstallSystem)
        -> Result<StayUpWatch, InstallRefusal> {
        var watch = watch
        watch.policy = policy
        guard policy.installs(watch.bundleID) else {
            return .failure(InstallRefusal(.notInstallable, "This installer watches only \(policy.bundleIDPrefix)'s apps, not \(watch.bundleID)."))
        }
        guard BundleInstall.destinationName(watch.install.destination, policy: policy) != nil else {
            return .failure(InstallRefusal(.badName, "\(watch.install.destination) isn't an app's place in \(policy.applications)."))
        }
        let folders = (policy.zipFolders + policy.watchFolders).compactMap { files.resolvingLinks($0) }
        for path in [watch.lockPath, watch.notePath] {
            let name = (path as NSString).lastPathComponent
            guard BundleInstall.refusal(name: name) == nil, let parent = files.resolvingLinks((path as NSString).deletingLastPathComponent),
                  folders.contains(where: { parent == $0 || BundleInstall.isInside(parent, $0) }) else {
                return .failure(InstallRefusal(.outsideFolders, "\(path) isn't in a folder this installer may write a watch's files in."))
            }
        }
        return .success(watch)
    }

    @discardableResult
    public static func run(_ watch: StayUpWatch, system: any WatchSystem) -> WatchNote {
        do { try WatchLock.take(watch.lockPath, system: system) } catch {
            // Watched anyway: the lock only keeps two watchers from undoing each other's work.
        }
        defer { WatchLock.release(watch.lockPath, system: system) }

        var watched: Int32?
        let failure = watchNewBuild(watch, system: system, found: { watched = $0 })
        let note: WatchNote
        if let failure {
            if let watched, system.isAlive(watched) { system.terminate(watched) }
            note = putBack(watch, because: failure, system: system)
        } else {
            if let backup = watch.install.backup { BundleInstall.discard(backup: backup, system: system.files) }
            note = WatchNote(outcome: .stayedUp, reason: nil, bundleID: watch.bundleID,
                             executableSHA256: watch.install.executableSHA256, at: system.now())
        }
        try? system.write(note.json, to: watch.notePath)
        return note
    }

    /// Nil once the new build has stayed up, else why not.
    static func watchNewBuild(_ watch: StayUpWatch, system: any WatchSystem, found: (Int32) -> Void) -> String? {
        // The app that asked, quitting.
        let quitBy = system.now().addingTimeInterval(watch.quitSeconds)
        while system.isAlive(watch.quittingPID), system.now() < quitBy { system.sleep(interval) }

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
                    let listener = watch.listenerMustBeWatched ? system.listenerPID(of: url) : nil
                    if listener == nil || listener == pid { break }
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
    static func putBack(_ watch: StayUpWatch, because failure: String, system: any WatchSystem) -> WatchNote {
        func note(_ outcome: WatchNote.Outcome, _ reason: String) -> WatchNote {
            WatchNote(outcome: outcome, reason: reason, bundleID: watch.bundleID, executableSHA256: watch.install.executableSHA256,
                      at: system.now())
        }
        guard let backup = watch.install.backup else {
            return note(.restoreFailed, "\(failure) There was no earlier build to put back.")
        }
        switch BundleInstall.restore(backup: backup, destination: watch.install.destination,
                                     installedExecutableSHA256: watch.install.executableSHA256, bundleID: watch.bundleID,
                                     policy: watch.policy, system: system.files) {
        case .success:
            _ = system.open(app: watch.install.destination)
            return note(.restored, failure)
        case .failure(let refusal):
            return note(.restoreFailed, "\(failure) The earlier build couldn't be put back: \(refusal.reason)")
        }
    }
}
