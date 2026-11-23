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
/// 1. the bundle id is one of the policy's apps, by its name there (so `<applications>/<name>.app` is that app's);
/// 2. the zip, its links resolved, is a file inside one of the policy's folders (never a link out of them);
/// 3. copied from one opening of it (a plain file, not through a link, no larger than the policy allows, its opened
///    path still in those folders) into a fresh folder of the service's own, the copy's SHA-256 is the one given:
///    only the copy is used from here on, so the app can't change the file between the check and the unpacking;
/// 4. the copy, unpacked into its own subfolder with `ditto -x -k --noqtn` within the policy's time limit, comes to
///    no more than the policy allows and holds exactly one app: a folder itself (never a link to one), of that bundle
///    id;
/// 5. its signature passes the policy's check (Apple's anchor and the service's own team always; by default its
///    Developer ID and notarization too);
/// 6. what is at the destination already is that app (or one of its earlier bundle ids), and the build isn't older
///    than it (`CFBundleVersion`) unless the policy allows downgrades; or nothing is there, unless the policy is
///    update-only.
///
/// Only then, the app checked again to be a folder, is any quarantine removed from it, it swapped into place in one
/// rename, and registered with LaunchServices. The copy it replaced is kept, with a manifest of where it came from and
/// what replaced it, until the caller discards it (the new build stayed up) or restores it (it didn't), by the opaque
/// id the install gave; one neither, that nothing runs from, is swept by an install after the policy's backup
/// lifetime. A refusal before the swap leaves the applications folder as it was.
public enum BundleInstall {
    /// The manifest beside a backup, in its folder.
    static let manifestName = "manifest.json"
    /// The subfolder a build is unpacked into.
    static let unpackedName = "unpacked"

    /// The install carried out: the app in place and its backup, or why not.
    public static func install(_ request: BundleInstallRequest, policy: InstallPolicy, system: any BundleInstallSystem,
                               now: Date = Date()) -> Result<InstallResult, InstallRefusal> {
        let bundleID = request.bundleID, name = request.name
        if let why = refusal(name: name) { return .failure(InstallRefusal(.badName, why)) }
        guard policy.installs(bundleID, name: name) else {
            return .failure(InstallRefusal(.notInstallable, "This installer doesn't install \(name) (\(bundleID))."))
        }
        guard let expected = normalized(sha256: request.sha256) else {
            return .failure(InstallRefusal(.badDigest, "The build's release lists no usable SHA-256 for its file."))
        }
        // The zip: a file in one of the policy's folders, its links resolved (so none leads out of them).
        guard let zip = system.resolvingLinks(request.zipPath), system.isFile(zip) else {
            return .failure(InstallRefusal(.noFile, "The build's file isn't there."))
        }
        let folders = policy.zipFolders.compactMap { system.resolvingLinks($0) }
        guard folders.contains(where: { isInside(zip, $0) }) else {
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
        do { copy = try system.copy(zip: zip, into: folder, within: folders, maxBytes: policy.maxZipBytes) } catch let refusal as InstallRefusal {
            return .failure(refusal)
        } catch {
            return .failure(InstallRefusal(.unreadable, "The build's file can't be read: \(error)"))
        }
        let digest: String
        do { digest = try system.sha256(ofFile: copy) } catch {
            return .failure(InstallRefusal(.unreadable, "The build's file can't be read: \(error)"))
        }
        guard digest == expected else {
            return .failure(InstallRefusal(.digestDiffers, "The build's file isn't the one its release lists (its SHA-256 differs)."))
        }
        let unpacked = "\(folder)/\(unpackedName)"
        do {
            try system.createFolder(unpacked)
            try system.unpack(zip: copy, into: unpacked, timeLimit: policy.unpackTimeLimit)
        } catch let refusal as InstallRefusal {
            return .failure(refusal)
        } catch {
            return .failure(InstallRefusal(.unpackFailed, "The build couldn't be unpacked: \(error)"))
        }
        system.remove(copy)
        guard system.size(of: unpacked) <= policy.maxUnpackedBytes else {
            return .failure(InstallRefusal(.tooLarge, "The build unpacks to more than this installer takes."))
        }
        let apps = system.entries(of: unpacked).filter { $0.hasSuffix(".app") }
        guard apps.count == 1 else { return .failure(InstallRefusal(.notOneApp, "The build has \(apps.count) apps in it, not one.")) }
        let new = "\(unpacked)/\(apps[0])"
        guard system.isRealFolder(new) else {
            return .failure(InstallRefusal(.notAFolder, "The build's app isn't a folder of its own (a link?), so it isn't installed."))
        }
        guard system.infoValue("CFBundleIdentifier", ofApp: new) == bundleID else {
            return .failure(InstallRefusal(.wrongBundleID, "The build is not \(name) (\(bundleID))."))
        }
        if let why = system.signatureRefusal(ofApp: new, signing: policy.signing) { return .failure(InstallRefusal(.badSignature, why)) }
        guard let executableSHA256 = executableDigest(ofApp: new, system: system) else {
            return .failure(InstallRefusal(.unreadable, "The build's main executable can't be read."))
        }

        // Where it goes: this app already, no newer than the build; or free.
        let destination = policy.destination(name: name)
        if system.exists(destination) {
            guard let there = system.infoValue("CFBundleIdentifier", ofApp: destination) else {
                return .failure(InstallRefusal(.destinationTaken,
                                               "\(destination) is there and isn't an app the installer can read: move it away, then install."))
            }
            guard policy.isSameApp(there, as: bundleID) else {
                return .failure(InstallRefusal(.destinationTaken, "\(destination) is another app (\(there)): move it away, then install."))
            }
            if !policy.allowsDowngrade, let installed = system.infoValue("CFBundleVersion", ofApp: destination),
               compare(system.infoValue("CFBundleVersion", ofApp: new) ?? "", installed) != .orderedDescending {
                return .failure(InstallRefusal(.downgrade, "The build isn't newer than the \(name) installed, so it isn't installed."))
            }
        } else if policy.updateOnly {
            return .failure(InstallRefusal(.notInstalled, "\(name) isn't installed, and this installer only updates it."))
        }

        // Every check passed: still a folder, no quarantine, then the swap.
        guard system.isRealFolder(new) else {
            return .failure(InstallRefusal(.notAFolder, "The build's app changed before it was put in place, so it isn't installed."))
        }
        do { try system.removeQuarantine(under: new) } catch {
            return .failure(InstallRefusal(.quarantine, "The build's quarantine couldn't be removed: \(error)"))
        }
        let old: String?
        do { old = try system.swap(new, into: destination) } catch {
            return .failure(InstallRefusal(.swapFailed, "The new build couldn't be put in place at \(destination): \(error)"))
        }
        system.register(app: destination)
        guard let old else { return .success(InstallResult(destination: destination, backup: nil, executableSHA256: executableSHA256)) }
        // The copy replaced, the backup: forgotten by LaunchServices (so nothing opens it by its bundle id), kept with
        // its manifest.
        system.unregister(app: old)
        let manifest = BackupManifest(bundleID: bundleID, name: name, destination: destination, installedExecutableSHA256: executableSHA256)
        guard let data = try? JSONEncoder().encode(manifest), (try? system.write(data, to: "\(folder)/\(manifestName)")) != nil else {
            // Without its manifest it can't be restored: kept until swept, and the install said to have no backup.
            keepFolder = true
            return .success(InstallResult(destination: destination, backup: nil, executableSHA256: executableSHA256))
        }
        keepFolder = true
        return .success(InstallResult(destination: destination, backup: (folder as NSString).lastPathComponent,
                                      executableSHA256: executableSHA256))
    }

    /// A backup put back where its install took it from, over the build that install put there: refused unless the
    /// backup is the service's own (its id, its manifest), its app one of the policy's, still a folder of that bundle
    /// id that passes the signature check, and what's at the destination is still that build (its main executable's
    /// SHA-256) or nothing. The build it takes out is removed (or, while a process runs from it, swept later).
    public static func restore(backup id: String, policy: InstallPolicy, system: any BundleInstallSystem) -> Result<Void, InstallRefusal> {
        guard let (folder, manifest) = backupFolder(id, system: system) else {
            return .failure(InstallRefusal(.backupMissing, "The earlier build isn't kept by this installer (any more)."))
        }
        guard policy.installs(manifest.bundleID, name: manifest.name), manifest.destination == policy.destination(name: manifest.name) else {
            return .failure(InstallRefusal(.notInstallable, "This installer doesn't put back \(manifest.name) (\(manifest.bundleID))."))
        }
        let unpacked = "\(folder)/\(unpackedName)"
        let apps = system.entries(of: unpacked).filter { $0.hasSuffix(".app") }
        guard apps.count == 1, case let app = "\(unpacked)/\(apps[0])", system.isRealFolder(app),
              let there = system.infoValue("CFBundleIdentifier", ofApp: app), policy.isSameApp(there, as: manifest.bundleID) else {
            return .failure(InstallRefusal(.backupInvalid, "The earlier build kept isn't whole, or isn't \(manifest.name)."))
        }
        if let why = system.signatureRefusal(ofApp: app, signing: policy.signing) {
            return .failure(InstallRefusal(.backupInvalid, "The earlier build kept no longer passes its check: \(why)"))
        }
        let destination = manifest.destination
        if system.exists(destination) {
            guard system.infoValue("CFBundleIdentifier", ofApp: destination) == manifest.bundleID,
                  executableDigest(ofApp: destination, system: system) == manifest.installedExecutableSHA256 else {
                return .failure(InstallRefusal(.installedChanged,
                                               "\(manifest.name) in place isn't the build this install put there any more, so it's left as it is."))
            }
        }
        do { try system.removeQuarantine(under: app) } catch {
            return .failure(InstallRefusal(.quarantine, "The earlier build's quarantine couldn't be removed: \(error)"))
        }
        let out: String?
        do { out = try system.swap(app, into: destination) } catch {
            return .failure(InstallRefusal(.swapFailed, "The earlier build couldn't be put back at \(destination): \(error)"))
        }
        system.register(app: destination)
        if let out { system.unregister(app: out) }
        system.remove("\(folder)/\(manifestName)")
        if !system.isInUse(folder) { removeFolder(folder, system: system) }
        return .success(())
    }

    /// A backup dropped (the new build stayed up), by its id: forgotten and removed, unless a process still runs from
    /// it (an app that updated itself, until it has quit), when a later install sweeps it. Whether it was one of the
    /// service's.
    @discardableResult
    public static func discard(backup id: String, system: any BundleInstallSystem) -> Bool {
        guard let (folder, _) = backupFolder(id, system: system) else { return false }
        system.remove("\(folder)/\(manifestName)")
        for entry in system.entries(of: "\(folder)/\(unpackedName)") where entry.hasSuffix(".app") {
            system.unregister(app: "\(folder)/\(unpackedName)/\(entry)")
        }
        if !system.isInUse(folder) { removeFolder(folder, system: system) }
        return true
    }

    /// A backup's folder and manifest, by its id: a plain name of a folder in the service's own folder, with a manifest.
    static func backupFolder(_ id: String, system: any BundleInstallSystem) -> (String, BackupManifest)? {
        guard refusal(name: id) == nil, !id.contains("."), let own = system.resolvingLinks(system.ownFolder) else { return nil }
        let folder = "\(own)/\(id)"
        guard system.isRealFolder(folder), let data = system.read("\(folder)/\(manifestName)"),
              let manifest = try? JSONDecoder().decode(BackupManifest.self, from: data) else { return nil }
        return (folder, manifest)
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
        for entry in system.entries(of: "\(folder)/\(unpackedName)") where entry.hasSuffix(".app") {
            system.unregister(app: "\(folder)/\(unpackedName)/\(entry)")
        }
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

    /// Two `CFBundleVersion`s compared by their dot-separated numbers (`1.10` after `1.9`; a missing part is 0).
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = lhs.split(separator: ".").map { Int($0) ?? 0 }, right = rhs.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0, b = index < right.count ? right[index] : 0
            if a != b { return a < b ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
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
    /// `..`, no hidden file, room for `.app` in a file name), nil when it is.
    static func refusal(name: String) -> String? {
        guard !name.isEmpty, name.utf8.count <= 251, !name.hasPrefix("."), !name.contains("/"), !name.contains(":"),
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
