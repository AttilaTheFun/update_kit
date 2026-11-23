import Foundation

/// How a build is put in /Applications by an installer service outside the App Sandbox (docs/Installing.md): the
/// rules alone, deciding from what they're shown and acting through what they're given (BundleInstallSystem), so the
/// same rules run on the Mac and in the tests (on Linux too).
///
/// macOS quarantines what a sandboxed process (or any child it spawns, ditto included) writes, and refuses to open an
/// app a sandboxed process made. So a sandboxed app only downloads a build, and its unsandboxed service, handed the
/// zip's path, the bundle id and name its release lists and the SHA-256 it gives, checks and installs it here. In
/// order, each refusing with a code and a plain reason, and nothing after it done:
///
/// 1. the bundle id is the policy's (`InstallPolicy.installs`);
/// 2. the name is a plain file name, so `<applications>/<name>.app` is in the applications folder;
/// 3. the zip, its links resolved, is a file inside one of the policy's folders (never a link out of them);
/// 4. copied, its bytes alone, into a fresh folder of the service's own, the copy's SHA-256 is the one given: only the
///    copy is used from here on, so the app can't change the file between the check and the unpacking;
/// 5. the copy, unpacked there with `ditto -x -k --noqtn` within the policy's time limit, holds exactly one app, of
///    that bundle id;
/// 6. its signature passes (`BundleInstallSystem.signatureRefusal`: the service's own team, and its Developer ID
///    and notarization wherever the app around the service has them);
/// 7. what is at the destination already is that app (or one of its earlier bundle ids), or nothing.
///
/// Only then is any quarantine removed from the new bundle, the bundle swapped into place in one rename, and
/// registered with LaunchServices. The copy it replaced is kept in the service's folder, its backup, until the caller
/// discards it (the new build stayed up) or restores it (it didn't); one neither, that nothing runs from, is swept by
/// an install after the policy's backup lifetime. A refusal before the swap leaves the applications folder as it was.
public enum BundleInstall {
    /// The install carried out: the app in place and its backup, or why not.
    public static func install(_ request: BundleInstallRequest, policy: InstallPolicy, system: any BundleInstallSystem,
                               now: Date = Date()) -> Result<InstallResult, InstallRefusal> {
        let bundleID = request.bundleID, name = request.name
        guard policy.installs(bundleID) else {
            return .failure(InstallRefusal(.notInstallable, "This installer installs only \(policy.bundleIDPrefix)'s apps, not \(bundleID)."))
        }
        if let why = refusal(name: name) { return .failure(InstallRefusal(.badName, why)) }
        guard let expected = normalized(sha256: request.sha256) else {
            return .failure(InstallRefusal(.digestDiffers, "The build's release lists no usable SHA-256 for its file."))
        }
        // The zip: a file in one of the policy's folders, its links resolved (so none leads out of them).
        guard let zip = system.resolvingLinks(request.zipPath), system.isFile(zip) else {
            return .failure(InstallRefusal(.noFile, "The build's file isn't there."))
        }
        guard policy.zipFolders.contains(where: { folder in system.resolvingLinks(folder).map { isInside(zip, $0) } ?? false }) else {
            return .failure(InstallRefusal(.outsideFolders, "The build's file isn't in a folder this installer takes builds from."))
        }

        // Copied where only the service writes, then checked and unpacked there, quarantining nothing.
        sweep(policy: policy, system: system, now: now)
        let folder: String
        do { folder = try system.makeFolder() } catch {
            return .failure(InstallRefusal(.unpackFailed, "The installer has no folder to unpack into: \(error)"))
        }
        var keepFolder = false
        defer { if !keepFolder { removeFolder(folder, system: system) } }
        let copy: String
        do { copy = try system.copy(zip: zip, into: folder) } catch {
            return .failure(InstallRefusal(.unreadable, "The build's file can't be read: \(error)"))
        }
        let digest: String
        do { digest = try system.sha256(ofFile: copy) } catch {
            return .failure(InstallRefusal(.unreadable, "The build's file can't be read: \(error)"))
        }
        guard digest == expected else {
            return .failure(InstallRefusal(.digestDiffers, "The build's file isn't the one its release lists (its SHA-256 differs)."))
        }
        do { try system.unpack(zip: copy, into: folder, timeLimit: policy.unpackTimeLimit) } catch let refusal as InstallRefusal {
            return .failure(refusal)
        } catch {
            return .failure(InstallRefusal(.unpackFailed, "The build couldn't be unpacked: \(error)"))
        }
        system.remove(copy)
        let apps = system.entries(of: folder).filter { $0.hasSuffix(".app") }
        guard apps.count == 1 else { return .failure(InstallRefusal(.notOneApp, "The build has \(apps.count) apps in it, not one.")) }
        let new = "\(folder)/\(apps[0])"
        guard system.infoValue("CFBundleIdentifier", ofApp: new) == bundleID else {
            return .failure(InstallRefusal(.wrongBundleID, "The build is not \(name) (\(bundleID))."))
        }
        if let why = system.signatureRefusal(ofApp: new) { return .failure(InstallRefusal(.badSignature, why)) }
        guard let executableSHA256 = executableDigest(ofApp: new, system: system) else {
            return .failure(InstallRefusal(.unreadable, "The build's main executable can't be read."))
        }

        // Where it goes: free, or this app already.
        let destination = policy.destination(name: name)
        if system.exists(destination) {
            guard let there = system.infoValue("CFBundleIdentifier", ofApp: destination) else {
                return .failure(InstallRefusal(.destinationTaken,
                                               "\(destination) is there and isn't an app the installer can read: move it away, then install."))
            }
            guard policy.isSameApp(there, as: bundleID) else {
                return .failure(InstallRefusal(.destinationTaken, "\(destination) is another app (\(there)): move it away, then install."))
            }
        }

        // Every check passed: no quarantine, then the swap.
        do { try system.removeQuarantine(under: new) } catch {
            return .failure(InstallRefusal(.quarantine, "The build's quarantine couldn't be removed: \(error)"))
        }
        let old: String?
        do { old = try system.swap(new, into: destination) } catch {
            return .failure(InstallRefusal(.swapFailed, "The new build couldn't be put in place at \(destination): \(error)"))
        }
        system.register(app: destination)
        if let old {
            // The copy replaced, the backup: forgotten by LaunchServices (so nothing opens it by its bundle id) and kept.
            system.unregister(app: old)
            keepFolder = true
        }
        return .success(InstallResult(destination: destination, backup: old, executableSHA256: executableSHA256))
    }

    /// The backup put back at `destination`, where the install put the build that's to go: refused unless the backup
    /// is the service's own, still a whole app of `bundleID` that passes the signature check, and what's at the
    /// destination is still the build the install put there (its main executable's SHA-256, `installedExecutableSHA256`),
    /// or nothing. The build it takes out is removed (or, while a process runs from it, swept later).
    public static func restore(backup: String, destination: String, installedExecutableSHA256: String, bundleID: String,
                               policy: InstallPolicy, system: any BundleInstallSystem) -> Result<Void, InstallRefusal> {
        guard let resolved = system.resolvingLinks(backup), let own = system.resolvingLinks(system.ownFolder), isInside(resolved, own),
              system.exists(resolved) else {
            return .failure(InstallRefusal(.backupMissing, "The earlier build isn't in the installer's folder any more."))
        }
        guard let there = system.infoValue("CFBundleIdentifier", ofApp: resolved), policy.isSameApp(there, as: bundleID) else {
            return .failure(InstallRefusal(.backupInvalid, "The earlier build kept isn't \(bundleID)."))
        }
        if let why = system.signatureRefusal(ofApp: resolved) {
            return .failure(InstallRefusal(.backupInvalid, "The earlier build kept no longer passes its check: \(why)"))
        }
        guard let name = destinationName(destination, policy: policy) else {
            return .failure(InstallRefusal(.badName, "\(destination) isn't an app's place in \(policy.applications)."))
        }
        if system.exists(destination) {
            guard system.infoValue("CFBundleIdentifier", ofApp: destination) == bundleID,
                  executableDigest(ofApp: destination, system: system) == normalized(sha256: installedExecutableSHA256) else {
                return .failure(InstallRefusal(.installedChanged,
                                               "\(name) in place isn't the build this install put there any more, so it's left as it is."))
            }
        }
        do { try system.removeQuarantine(under: resolved) } catch {
            return .failure(InstallRefusal(.quarantine, "The earlier build's quarantine couldn't be removed: \(error)"))
        }
        let out: String?
        do { out = try system.swap(resolved, into: destination) } catch {
            return .failure(InstallRefusal(.swapFailed, "The earlier build couldn't be put back at \(destination): \(error)"))
        }
        system.register(app: destination)
        if let out {
            system.unregister(app: out)
            let folder = (out as NSString).deletingLastPathComponent
            if !system.isInUse(folder) { removeFolder(folder, system: system) }
        }
        return .success(())
    }

    /// The backup dropped (the new build stayed up): forgotten and removed, its folder with it, unless a process still
    /// runs from it (an app that updated itself, until it has quit), when a later install sweeps it. Only the service's
    /// own folders are touched: whether it was one.
    @discardableResult
    public static func discard(backup: String, system: any BundleInstallSystem) -> Bool {
        guard let resolved = system.resolvingLinks(backup), let own = system.resolvingLinks(system.ownFolder),
              isInside(resolved, own) else { return false }
        let folder = (resolved as NSString).deletingLastPathComponent
        guard isInside(folder, own) else { return false }
        system.unregister(app: resolved)
        if !system.isInUse(folder) { removeFolder(folder, system: system) }
        return true
    }

    /// What earlier installs left in the service's folder: each folder nothing runs from and older than the policy's
    /// backup lifetime removed.
    static func sweep(policy: InstallPolicy, system: any BundleInstallSystem, now: Date) {
        let own = system.ownFolder
        for entry in system.entries(of: own) {
            let folder = "\(own)/\(entry)"
            guard let changed = system.modified(folder), now.timeIntervalSince(changed) > policy.backupLifetime,
                  !system.isInUse(folder) else { continue }
            removeFolder(folder, system: system)
        }
    }

    /// A folder of the service's removed, every app in it forgotten by LaunchServices first.
    static func removeFolder(_ folder: String, system: any BundleInstallSystem) {
        for entry in system.entries(of: folder) where entry.hasSuffix(".app") { system.unregister(app: "\(folder)/\(entry)") }
        system.remove(folder)
    }

    /// The SHA-256 of an app's main executable (its Info.plist's CFBundleExecutable, in Contents/MacOS), nil when it
    /// can't be read.
    static func executableDigest(ofApp app: String, system: any BundleInstallSystem) -> String? {
        guard let executable = system.infoValue("CFBundleExecutable", ofApp: app), refusal(name: executable) == nil else { return nil }
        let path = "\(app)/Contents/MacOS/\(executable)"
        guard system.isFile(path) else { return nil }
        return try? system.sha256(ofFile: path)
    }

    /// The app's name, when `destination` is `<applications>/<name>.app` for a name an install takes.
    static func destinationName(_ destination: String, policy: InstallPolicy) -> String? {
        let prefix = policy.applications.hasSuffix("/") ? policy.applications : policy.applications + "/"
        guard destination.hasPrefix(prefix), destination.hasSuffix(".app") else { return nil }
        let name = String(destination.dropFirst(prefix.count).dropLast(4))
        return refusal(name: name) == nil ? name : nil
    }

    /// Whether `path` is inside `folder` (both resolved), not `folder` itself.
    static func isInside(_ path: String, _ folder: String) -> Bool {
        let folder = folder.hasSuffix("/") ? String(folder.dropLast()) : folder
        return !folder.isEmpty && path.hasPrefix(folder + "/") && path.count > folder.count + 1
    }

    /// Why `name` isn't a name an app may have in the applications folder (one plain path component, none of `.` and
    /// `..`, no hidden file), nil when it is.
    static func refusal(name: String) -> String? {
        guard !name.isEmpty, name.count <= 200, !name.hasPrefix("."), !name.contains("/"), !name.contains(":"),
              !name.contains("\0"), name.trimmingCharacters(in: .whitespaces) == name else {
            return "\"\(name)\" isn't a name an app can have in /Applications."
        }
        return nil
    }

    /// A SHA-256 as a release writes it: 64 hex digits (lowercased here).
    static func normalized(sha256: String) -> String? {
        let lower = sha256.lowercased()
        guard lower.count == 64, lower.allSatisfy({ $0.isHexDigit }) else { return nil }
        return lower
    }
}
