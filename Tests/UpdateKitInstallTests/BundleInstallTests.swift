import Foundation
import Testing
@testable import UpdateKitInstall

@Suite struct BundleInstallTests {
    @Test func installsWhatItsReleaseListsInOneSwapAndKeepsTheBackupWithItsManifest() throws {
        let mac = macWithDownload()
        let result = try #require(install(mac).value)
        let new = "\(mac.unpacked)/App.app"
        // Copied into the service's folder, the copy unpacked into its own subfolder and removed, then (all checked)
        // unquarantined, swapped, registered; the replaced copy forgotten by LaunchServices and kept.
        #expect(mac.steps == [
            .copy(downloadedZip), .unpack(mac.copied), .remove(mac.copied), .removeQuarantine(new),
            .swap(new, "/Applications/App.app"), .register("/Applications/App.app"), .unregister(new),
        ])
        #expect(result == InstallResult(destination: "/Applications/App.app", backup: "1", executableSHA256: newBuild))
        #expect(mac.apps[new]?.version == "1")
        let manifest = try JSONDecoder().decode(BackupManifest.self, from: try #require(mac.files["\(mac.folder)/manifest.json"]))
        #expect(manifest == BackupManifest(bundleID: "com.example.App", name: "App", destination: "/Applications/App.app",
                                           installedExecutableSHA256: newBuild))
        // The policy's check asked: Developer ID by default.
        #expect(mac.signingsAsked == [.developerID])
    }

    @Test func aFreshInstallKeepsNothingUnlessUpdateOnly() throws {
        let mac = macWithDownload()
        mac.apps["/Applications/App.app"] = nil
        var updating = policy
        updating.updateOnly = true
        #expect(install(mac, policy: updating).refusal?.code == .notInstalled)
        #expect(!mac.swapped)
        let result = try #require(install(mac).value)
        #expect(result.backup == nil)
        #expect(mac.apps["/Applications/App.app"]?.bundleID == "com.example.App")
        #expect(mac.removals.last == mac.folder)
    }

    @Test func installsExactlyThePolicysAppsByTheirNames() {
        let mac = macWithDownload()
        #expect(install(mac, bundleID: "com.example.Application").refusal?.code == .notInstallable)
        // An app the policy has, by another name.
        #expect(install(mac, name: "Other").refusal?.code == .notInstallable)
        // Not a prefix: a bundle id under the app's isn't the app's.
        #expect(install(mac, bundleID: "com.example.App.Agent", name: "App").refusal?.code == .notInstallable)
        for name in ["", "../App", "a/b", ".App", " App", "App:1", String(repeating: "x", count: 252)] {
            #expect(install(mac, name: name).refusal?.code == .badName)
        }
        #expect(mac.steps.isEmpty)
    }

    @Test func takesOnlyAZipInThePolicysFolders() {
        let mac = macWithDownload()
        let elsewhere = "\(home)/Downloads/app.zip"
        mac.files[elsewhere] = Data()
        mac.digests[elsewhere] = buildSHA
        #expect(install(mac, zip: elsewhere).refusal?.code == .outsideFolders)
        // The group's container is one of them.
        let inGroup = "\(group)/Offers/app.zip"
        mac.files[inGroup] = Data()
        mac.digests[inGroup] = buildSHA
        mac.contents[inGroup] = mac.contents[downloadedZip]
        #expect(install(mac, zip: inGroup).value != nil)
        #expect(install(mac, zip: "\(container)/nothing.zip").refusal?.code == .noFile)
    }

    @Test func resolvesLinksBeforeLookingWhereTheZipIs() {
        // The container's Downloads is a link to the user's: a zip through it is the user's, not the container's.
        let mac = macWithDownload()
        let real = "\(home)/Downloads/app.zip"
        mac.files[real] = Data()
        mac.digests[real] = buildSHA
        mac.links["\(container)/Downloads"] = "\(home)/Downloads"
        #expect(install(mac, zip: "\(container)/Downloads/app.zip").refusal?.code == .outsideFolders)
        #expect(!mac.unpackedAny)
    }

    @Test func checksAndUnpacksItsOwnCopyNotTheAppsFile() {
        // The app changes its file once the service has copied it: the copy, the release's build, is what's installed.
        let mac = macWithDownload()
        mac.afterCopy = { mac in
            mac.digests[downloadedZip] = String(repeating: "ef", count: 32)
            mac.contents[downloadedZip] = [(name: "App.app", app: .init(bundleID: "com.example.App", version: "9", build: "evil"))]
        }
        #expect(install(mac).value?.executableSHA256 == newBuild)
        #expect(!mac.steps.contains(.unpack(downloadedZip)))
    }

    @Test func refusesAFileWhoseSHA256DiffersOrThatIsTooLarge() {
        let mac = macWithDownload()
        #expect(install(mac, sha256: String(repeating: "cd", count: 32)).refusal?.code == .digestDiffers)
        #expect(!mac.unpackedAny)
        #expect(mac.files[mac.copied] == nil)
        #expect(mac.removals.last == mac.folder)
        #expect(install(mac, sha256: "").refusal?.code == .badDigest)
        mac.zipSizes[downloadedZip] = policy.maxZipBytes + 1
        #expect(install(mac).refusal?.code == .tooLarge)
        mac.zipSizes = [:]
        mac.unpackedSize = policy.maxUnpackedBytes + 1
        #expect(install(mac).refusal?.code == .tooLarge)
        #expect(!mac.swapped)
        // What the zip says, before it's unpacked: too much, or nothing at all.
        mac.unpackedSize = 1
        mac.declaredSize = .some(policy.maxUnpackedBytes + 1)
        let before = mac.steps.count
        #expect(install(mac).refusal?.code == .tooLarge)
        #expect(!mac.steps.dropFirst(before).contains { if case .unpack = $0 { return true } else { return false } })
        mac.declaredSize = .some(nil)
        #expect(install(mac).refusal?.code == .tooLarge)
        mac.declaredSize = .none
        mac.unpackedSize = 1
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
        mac.contents[downloadedZip]?.append((name: "Other.app", app: .init(bundleID: "com.example.App.Helper")))
        #expect(install(mac).refusal?.code == .notOneApp)
        #expect(!mac.swapped)
        #expect(mac.steps.contains(.unregister("\(mac.unpacked)/Other.app")))
    }

    @Test func refusesAnAppThatIsALinkOrBecomesOne() {
        // A zip whose app is a link (to a genuine build in the app's own container): never swapped into place.
        let mac = macWithDownload()
        mac.afterUnpack = { mac in mac.linkedApps.insert("\(mac.unpacked)/App.app") }
        #expect(install(mac).refusal?.code == .notAFolder)
        #expect(!mac.swapped)
    }

    @Test func refusesABuildOfAnotherBundleIDOrABadSignature() {
        let mac = macWithDownload()
        mac.contents[downloadedZip] = [(name: "App.app", app: .init(bundleID: "com.example.App.Helper", version: "2"))]
        #expect(install(mac).refusal?.code == .wrongBundleID)
        let signed = macWithDownload()
        signed.badSignatures.insert("\(signed.ownFolder)/1/unpacked/App.app")
        #expect(install(signed).refusal?.code == .badSignature)
        #expect(!signed.swapped)
    }

    @Test func refusesAnOlderOrTheSameBuildUnlessDowngradesAreAllowed() {
        let mac = macWithDownload()
        mac.apps["/Applications/App.app"]?.version = "2"
        #expect(install(mac).refusal?.code == .downgrade)
        mac.apps["/Applications/App.app"]?.version = "10"
        #expect(install(mac).refusal?.code == .downgrade)
        var choosing = policy
        choosing.allowsDowngrade = true
        #expect(install(mac, policy: choosing).value != nil)
        #expect(BundleInstall.compare("1.10", "1.9") == .orderedDescending)
        #expect(BundleInstall.compare("2", "2.0") == .orderedSame)
        #expect(BundleInstall.compare("3b", "2") == .orderedDescending)
        #expect(BundleInstall.compare("1.x", "1.0") == .orderedSame)
    }

    @Test func replacesOnlyTheSameAppAtItsName() {
        let mac = macWithDownload()
        mac.apps["/Applications/App.app"] = .init(bundleID: "com.example.Other")
        #expect(install(mac).refusal?.code == .destinationTaken)
        // An earlier bundle id of the app is the app.
        mac.apps["/Applications/App.app"] = .init(bundleID: "com.example.App.Beta")
        #expect(install(mac).value != nil)
    }

    @Test func discardRemovesTheBackupByItsIdUnlessItRuns() throws {
        let mac = macWithDownload()
        let backup = try #require(install(mac).value?.backup)
        let app = "\(mac.ownFolder)/\(backup)/unpacked/App.app"
        mac.running = ["\(app)/Contents/MacOS/App"]
        #expect(BundleInstall.discard(backup: backup, system: mac))
        #expect(mac.apps[app] != nil)
        mac.running = []
        mac.files["\(mac.ownFolder)/\(backup)/manifest.json"] = try JSONEncoder().encode(
            BackupManifest(bundleID: "com.example.App", name: "App", destination: "/Applications/App.app", installedExecutableSHA256: newBuild))
        #expect(BundleInstall.discard(backup: backup, system: mac))
        #expect(mac.apps[app] == nil)
        // Never a path, or anything not the service's.
        for id in ["/Applications/App.app", "..", "../x", "1.app", "nothing"] {
            #expect(!BundleInstall.discard(backup: id, system: mac))
        }
        #expect(mac.apps["/Applications/App.app"] != nil)
    }

    @Test func aLaterInstallSweepsOnlyOldBackupsNothingRunsFrom() throws {
        let mac = macWithDownload()
        let old = try #require(install(mac).value?.backup)
        let young = "\(mac.ownFolder)/\(old)"
        // Another download of build 2 over build 1 again: the first backup, a day old, swept; a young one kept.
        mac.apps["/Applications/App.app"]?.version = "1"
        mac.folders[young] = now
        _ = install(mac)
        #expect(!mac.removals.contains(young))
        mac.folders[young] = now.addingTimeInterval(-policy.backupLifetime - 1)
        mac.apps["/Applications/App.app"]?.version = "1"
        _ = install(mac)
        #expect(mac.removals.contains(young))
    }

    @Test func restorePutsTheBackupBackWhereItCameFrom() throws {
        let mac = macWithDownload()
        let result = try #require(install(mac).value)
        let backup = try #require(result.backup)
        #expect(BundleInstall.restore(backup: backup, policy: policy, system: mac).refusal == nil)
        #expect(mac.apps["/Applications/App.app"]?.version == "1")
        #expect(mac.removals.last == "\(mac.ownFolder)/\(backup)")
        // Gone once restored.
        #expect(BundleInstall.restore(backup: backup, policy: policy, system: mac).refusal?.code == .backupMissing)
    }

    @Test func restoreWithTheDestinationGonePutsItBackThere() throws {
        let mac = macWithDownload()
        let result = try #require(install(mac).value)
        mac.apps["/Applications/App.app"] = nil
        #expect(BundleInstall.restore(backup: try #require(result.backup), policy: policy, system: mac).refusal == nil)
        #expect(mac.apps["/Applications/App.app"]?.version == "1")
    }

    @Test func restoreRefusesWhenTheBuildInPlaceChanged() throws {
        let mac = macWithDownload()
        let result = try #require(install(mac).value)
        mac.apps["/Applications/App.app"]?.build = String(repeating: "33", count: 32)
        let restored = BundleInstall.restore(backup: try #require(result.backup), policy: policy, system: mac)
        #expect(restored.refusal?.code == .installedChanged)
        #expect(mac.apps["/Applications/App.app"]?.build == String(repeating: "33", count: 32))
    }

    @Test func restoreRefusesABackupNotWholeOrNotThePolicys() throws {
        let mac = macWithDownload()
        let result = try #require(install(mac).value)
        let backup = try #require(result.backup)
        let app = "\(mac.ownFolder)/\(backup)/unpacked/App.app"
        func restore(_ id: String = backup, policy: InstallPolicy = policy) -> InstallRefusal.Code? {
            BundleInstall.restore(backup: id, policy: policy, system: mac).refusal?.code
        }
        #expect(restore("../\(backup)") == .backupMissing)
        // Another service's policy (another app's) never restores it.
        #expect(restore(policy: InstallPolicy(apps: ["com.example.Other": "Other"], zipFolders: [])) == .notInstallable)
        mac.badSignatures.insert(app)
        #expect(restore() == .backupInvalid)
        mac.badSignatures = []
        mac.linkedApps.insert(app)
        #expect(restore() == .backupInvalid)
        mac.linkedApps = []
        mac.apps[app]?.bundleID = "com.example.Other"
        #expect(restore() == .backupInvalid)
        #expect(mac.apps["/Applications/App.app"]?.build == newBuild)
    }

    @Test func refusalsAreCodableWithStableCodesAndUnknownOnesRead() throws {
        let refusal = InstallRefusal(.watchInProgress, "Another update is being watched.")
        let data = try JSONEncoder().encode(refusal)
        #expect(String(decoding: data, as: UTF8.self).contains("\"watchInProgress\""))
        #expect(try JSONDecoder().decode(InstallRefusal.self, from: data) == refusal)
        let newer = try JSONDecoder().decode(InstallRefusal.self, from: Data(#"{"code":"somethingNew","reason":"why"}"#.utf8))
        #expect(newer.code == .unknown)
        #expect(newer.reason == "why")
    }
}
