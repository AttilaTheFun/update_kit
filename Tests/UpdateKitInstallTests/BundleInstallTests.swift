import Foundation
import Testing
@testable import UpdateKitInstall

@Suite struct BundleInstallTests {
    @Test func installsWhatItsReleaseListsInOneSwapAndKeepsTheBackup() throws {
        let mac = macWithDownload()
        let result = try #require(install(mac).value)
        let new = "\(mac.folder)/App.app"
        // Copied into the service's folder, the copy unpacked and removed, then (all checked) unquarantined, swapped,
        // registered; the replaced copy forgotten by LaunchServices and kept where the new build was unpacked.
        #expect(mac.steps == [
            .copy(downloadedZip), .unpack(mac.copied), .remove(mac.copied), .removeQuarantine(new),
            .swap(new, "/Applications/App.app"), .register("/Applications/App.app"), .unregister(new),
        ])
        #expect(result == InstallResult(destination: "/Applications/App.app", backup: new, executableSHA256: newBuild))
        #expect(mac.apps[new]?.bundleID == "com.example.App")
        #expect(mac.apps["/Applications/App.app"]?.build == newBuild)
    }

    @Test func aFreshInstallIsARenameAndKeepsNothing() throws {
        let mac = macWithDownload()
        mac.apps["/Applications/App.app"] = nil
        let result = try #require(install(mac).value)
        #expect(result.backup == nil)
        #expect(mac.apps["/Applications/App.app"]?.bundleID == "com.example.App")
        #expect(mac.removals.last == mac.folder)
    }

    @Test func installsThePrefixsAppsAndNoOther() {
        #expect(policy.installs("com.example.App"))
        #expect(policy.installs("com.example.App.Helper"))
        #expect(!policy.installs("com.example.Application"))
        #expect(!policy.installs("com.example"))
        #expect(!policy.installs("com.example.App."))
        #expect(!policy.installs("com.example.App..x"))
        #expect(!policy.installs("com.example.App.a/b"))
        let mac = macWithDownload()
        #expect(install(mac, bundleID: "com.example.Application").refusal?.code == .notInstallable)
        #expect(mac.steps.isEmpty)
    }

    @Test func takesOnlyAZipInThePolicysFolders() {
        let mac = macWithDownload()
        let elsewhere = "\(home)/Downloads/app.zip"
        mac.files.insert(elsewhere)
        mac.digests[elsewhere] = buildSHA
        #expect(install(mac, zip: elsewhere).refusal?.code == .outsideFolders)
        // The group's container is one of them.
        let inGroup = "\(group)/Offers/app.zip"
        mac.files.insert(inGroup)
        mac.digests[inGroup] = buildSHA
        mac.contents[inGroup] = mac.contents[downloadedZip]
        #expect(install(mac, zip: inGroup).value != nil)
        #expect(install(mac, zip: "\(container)/nothing.zip").refusal?.code == .noFile)
    }

    @Test func resolvesLinksBeforeLookingWhereTheZipIs() {
        // The container's Downloads is a link to the user's: a zip through it is the user's, not the container's.
        let mac = macWithDownload()
        let real = "\(home)/Downloads/app.zip"
        mac.files.insert(real)
        mac.digests[real] = buildSHA
        mac.links["\(container)/Downloads"] = "\(home)/Downloads"
        #expect(install(mac, zip: "\(container)/Downloads/app.zip").refusal?.code == .outsideFolders)
        #expect(!mac.unpacked)
    }

    @Test func checksAndUnpacksItsOwnCopyNotTheAppsFile() {
        // The app changes its file once the service has copied it: the copy, the release's build, is what's installed.
        let mac = macWithDownload()
        mac.afterCopy = { mac in
            mac.digests[downloadedZip] = String(repeating: "ef", count: 32)
            mac.contents[downloadedZip] = [(name: "App.app", app: .init(bundleID: "com.example.App", build: "evil"))]
        }
        #expect(install(mac).value?.executableSHA256 == newBuild)
        #expect(!mac.steps.contains(.unpack(downloadedZip)))
    }

    @Test func refusesAFileWhoseSHA256DiffersAndRemovesItsCopy() {
        let mac = macWithDownload()
        #expect(install(mac, sha256: String(repeating: "cd", count: 32)).refusal?.code == .digestDiffers)
        #expect(!mac.unpacked)
        #expect(!mac.files.contains(mac.copied))
        #expect(mac.removals.last == mac.folder)
        // One that isn't a SHA-256 at all, refused before the file is looked at; the case doesn't matter.
        #expect(install(mac, sha256: "").refusal?.code == .digestDiffers)
        #expect(install(mac, sha256: buildSHA.uppercased()).value != nil)
    }

    @Test func aStuckUnpackingIsRefusedWithItsCode() {
        let mac = macWithDownload()
        mac.unpackFails = InstallRefusal(.unpackTimedOut, "Unpacking the build took longer than 300 seconds, so it was stopped.")
        #expect(install(mac).refusal?.code == .unpackTimedOut)
        #expect(!mac.swapped)
        #expect(mac.removals.last == mac.folder)
    }

    @Test func refusesABuildWithTwoApps() {
        let mac = macWithDownload()
        mac.contents[downloadedZip]?.append((name: "Other.app", app: .init(bundleID: "com.example.App.Other")))
        #expect(install(mac).refusal?.code == .notOneApp)
        #expect(!mac.swapped)
        #expect(mac.steps.contains(.unregister("\(mac.folder)/Other.app")))
    }

    @Test func refusesABuildOfAnotherBundleID() {
        let mac = macWithDownload()
        mac.contents[downloadedZip] = [(name: "App.app", app: .init(bundleID: "com.example.App.Helper"))]
        #expect(install(mac).refusal?.code == .wrongBundleID)
        #expect(!mac.swapped)
    }

    @Test func refusesABadSignatureBeforeTouchingTheApplicationsFolder() {
        let mac = macWithDownload()
        mac.badSignatures.insert("\(mac.ownFolder)/1/App.app")
        #expect(install(mac).refusal?.code == .badSignature)
        #expect(!mac.swapped)
        #expect(mac.apps["/Applications/App.app"]?.build != newBuild)
    }

    @Test func replacesOnlyTheSameAppAtItsName() {
        let mac = macWithDownload()
        mac.apps["/Applications/App.app"] = .init(bundleID: "com.example.Other")
        #expect(install(mac).refusal?.code == .destinationTaken)
        // An earlier bundle id of the app is the app.
        mac.apps["/Applications/App.app"] = .init(bundleID: "com.example.App.Beta")
        #expect(install(mac).value != nil)
    }

    @Test func refusesANameOutsideTheApplicationsFolder() {
        let mac = macWithDownload()
        for name in ["", "../App", "a/b", ".App", " App", "App:1"] {
            #expect(install(mac, name: name).refusal?.code == .badName)
        }
        #expect(mac.steps.isEmpty)
    }

    @Test func discardRemovesTheBackupUnlessItRuns() throws {
        let mac = macWithDownload()
        let backup = try #require(install(mac).value?.backup)
        mac.running = ["\(backup)/Contents/MacOS/App"]
        #expect(BundleInstall.discard(backup: backup, system: mac))
        #expect(mac.apps[backup] != nil)
        mac.running = []
        #expect(BundleInstall.discard(backup: backup, system: mac))
        #expect(mac.apps[backup] == nil)
        // Never a path outside the service's folder.
        #expect(!BundleInstall.discard(backup: "/Applications/App.app", system: mac))
        #expect(mac.apps["/Applications/App.app"] != nil)
    }

    @Test func aLaterInstallSweepsOnlyOldBackupsNothingRunsFrom() throws {
        let mac = macWithDownload()
        let backup = try #require(install(mac).value?.backup)
        let kept = (backup as NSString).deletingLastPathComponent
        // A day later than the backup's folder was made, with another download: swept.
        mac.folders[kept] = now.addingTimeInterval(-policy.backupLifetime - 1)
        mac.running = []
        _ = install(mac)
        #expect(mac.removals.contains(kept))
        // A young one, or one something runs from, stays.
        let young = try #require(install(mac).value?.backup)
        mac.folders[(young as NSString).deletingLastPathComponent] = now
        _ = install(mac)
        #expect(mac.apps[young] != nil)
    }

    @Test func restorePutsTheBackupBackAndRemovesTheBuildItReplaces() throws {
        let mac = macWithDownload()
        let result = try #require(install(mac).value)
        let backup = try #require(result.backup)
        let restored = BundleInstall.restore(backup: backup, destination: result.destination,
                                             installedExecutableSHA256: result.executableSHA256, bundleID: "com.example.App",
                                             policy: policy, system: mac)
        #expect(restored.refusal == nil)
        #expect(mac.apps["/Applications/App.app"]?.build != newBuild)
        #expect(mac.apps["/Applications/App.app"]?.bundleID == "com.example.App")
        #expect(mac.removals.last == (backup as NSString).deletingLastPathComponent)
    }

    @Test func restoreRefusesWhenTheBuildInPlaceChanged() throws {
        let mac = macWithDownload()
        let result = try #require(install(mac).value)
        // Something else (another update, the person) put another build there since.
        mac.apps["/Applications/App.app"]?.build = String(repeating: "33", count: 32)
        let restored = BundleInstall.restore(backup: try #require(result.backup), destination: result.destination,
                                             installedExecutableSHA256: result.executableSHA256, bundleID: "com.example.App",
                                             policy: policy, system: mac)
        #expect(restored.refusal?.code == .installedChanged)
        #expect(mac.apps["/Applications/App.app"]?.build == String(repeating: "33", count: 32))
    }

    @Test func restoreRefusesABackupThatIsntWholeOrTheServices() throws {
        let mac = macWithDownload()
        let result = try #require(install(mac).value)
        let backup = try #require(result.backup)
        func restore(_ path: String, destination: String = result.destination) -> InstallRefusal.Code? {
            BundleInstall.restore(backup: path, destination: destination, installedExecutableSHA256: result.executableSHA256,
                                  bundleID: "com.example.App", policy: policy, system: mac).refusal?.code
        }
        #expect(restore("\(home)/Desktop/App.app") == .backupMissing)
        #expect(restore(backup, destination: "/Applications/../tmp/App.app") == .badName)
        mac.badSignatures.insert(backup)
        #expect(restore(backup) == .backupInvalid)
        mac.badSignatures = []
        mac.apps[backup]?.bundleID = "com.example.Other"
        #expect(restore(backup) == .backupInvalid)
        #expect(mac.apps["/Applications/App.app"]?.build == newBuild)
    }

    @Test func refusalsAreCodableWithStableCodes() throws {
        let refusal = InstallRefusal(.watchInProgress, "Another update is being watched.")
        let data = try JSONEncoder().encode(refusal)
        #expect(String(decoding: data, as: UTF8.self).contains("\"watchInProgress\""))
        #expect(try JSONDecoder().decode(InstallRefusal.self, from: data) == refusal)
    }
}
