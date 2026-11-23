#if os(macOS)
import Darwin
import Foundation
import Testing
@testable import UpdateKitInstall

/// The install rules on a real Mac (MacBundleInstallSystem): real apps, signed ad hoc, zipped by ditto (or by hand,
/// for what ditto wouldn't make), installed into a folder standing for /Applications. The test runner is ad hoc
/// signed, as a test build of a service is, so its policy is `adHocForTests` (a debug build's). Run on a Mac (a VM),
/// not on Linux.
@Suite(.serialized) struct MacInstallTests {
    let root: String
    let container: String
    let applications: String
    let files: MacBundleInstallSystem

    init() throws {
        let made = (NSTemporaryDirectory() as NSString).appendingPathComponent("update-kit-tests-\(UUID().uuidString)")
        root = URL(fileURLWithPath: made).resolvingSymlinksInPath().path
        container = "\(root)/Container"
        applications = "\(root)/Applications"
        for folder in [container, applications] { try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true) }
        files = MacBundleInstallSystem(ownFolder: "\(root)/Service")
    }

    var policy: InstallPolicy {
        InstallPolicy(apps: ["com.example.TestApp": "TestApp"], zipFolders: [container], signing: .adHocForTests, applications: applications,
                      watchLockPath: "\(root)/watch.lock", watchNotePath: "\(root)/watch.json")
    }

    /// A minimal app, signed ad hoc: its Info.plist, a main executable, and `extra` bytes of a resource.
    @discardableResult
    func makeApp(at path: String, version: String, extra: Int = 0) throws -> String {
        let contents = "\(path)/Contents"
        try FileManager.default.createDirectory(atPath: "\(contents)/MacOS", withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "com.example.TestApp", "CFBundleExecutable": "TestApp",
                                   "CFBundleVersion": version, "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: URL(fileURLWithPath: "\(contents)/Info.plist"))
        // A copy of /usr/bin/true: a real Mach-O to sign.
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: "\(contents)/MacOS/TestApp")
        if extra > 0 {
            try FileManager.default.createDirectory(atPath: "\(contents)/Resources", withIntermediateDirectories: true)
            try Data(count: extra).write(to: URL(fileURLWithPath: "\(contents)/Resources/blob"))
        }
        try run("/usr/bin/codesign", ["--force", "--sign", "-", path])
        return path
    }

    func zip(_ app: String, as name: String = "build.zip") throws -> (path: String, sha256: String) {
        let zip = "\(container)/\(name)"
        try? FileManager.default.removeItem(atPath: zip)
        try run("/usr/bin/ditto", ["-c", "-k", "--keepParent", app, zip])
        return (zip, try files.sha256(ofFile: zip))
    }

    func run(_ path: String, _ arguments: [String]) throws {
        let result = MacBundleInstallSystem.run(path, arguments, timeLimit: 60)
        guard result.status == 0 else { throw MacBundleInstallSystem.Failure(description: "\(path) \(arguments): \(result.output)") }
    }

    func install(_ zip: (path: String, sha256: String), policy: InstallPolicy? = nil) -> Result<InstallResult, InstallRefusal> {
        BundleInstall.install(BundleInstallRequest(zipPath: zip.path, bundleID: "com.example.TestApp", sha256: zip.sha256, name: "TestApp"),
                              policy: policy ?? self.policy, system: files)
    }

    func version(at path: String) -> String? { files.infoValue("CFBundleVersion", ofApp: path) }

    func quarantined(_ path: String) -> Bool { getxattr(path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) >= 0 }

    @Test func installsARealBuildUnquarantinedAndRestoresTheOneItReplaced() throws {
        defer { try? FileManager.default.removeItem(atPath: root) }
        try makeApp(at: "\(applications)/TestApp.app", version: "1")
        let zip = try zip(try makeApp(at: "\(root)/Build/TestApp.app", version: "2"))
        // As a sandboxed app's download would be.
        let mark = "0082;00000000;Test;"
        #expect(setxattr(zip.path, "com.apple.quarantine", mark, mark.utf8.count, 0, XATTR_NOFOLLOW) == 0)
        let result = try #require(install(zip).value)
        #expect(version(at: "\(applications)/TestApp.app") == "2")
        #expect(!quarantined("\(applications)/TestApp.app"))
        #expect(!quarantined("\(applications)/TestApp.app/Contents/MacOS/TestApp"))
        let backup = try #require(result.backup)
        #expect(BundleInstall.restore(backup: backup, policy: policy, system: files).refusal == nil)
        #expect(version(at: "\(applications)/TestApp.app") == "1")
    }

    @Test func refusesTheSameBuildAgainAndAFreshInstallWhenUpdateOnly() throws {
        defer { try? FileManager.default.removeItem(atPath: root) }
        let zip = try zip(try makeApp(at: "\(root)/Build/TestApp.app", version: "2"))
        var updating = policy
        updating.updateOnly = true
        #expect(install(zip, policy: updating).refusal?.code == .notInstalled)
        #expect(install(zip).value != nil)
        #expect(install(zip).refusal?.code == .downgrade)
    }

    @Test func refusesAZipWhoseAppIsALink() throws {
        defer { try? FileManager.default.removeItem(atPath: root) }
        // A genuine build somewhere the app can write, and a zip holding only a link to it named as the app.
        try makeApp(at: "\(container)/Genuine/TestApp.app", version: "2")
        try FileManager.default.createDirectory(atPath: "\(root)/Linked", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: "\(root)/Linked/TestApp.app", withDestinationPath: "\(container)/Genuine/TestApp.app")
        let zipPath = "\(container)/linked.zip"
        try run("/usr/bin/ditto", ["-c", "-k", "\(root)/Linked", zipPath])
        let refusal = install((zipPath, try files.sha256(ofFile: zipPath))).refusal
        #expect(refusal?.code == .notAFolder)
        #expect(!FileManager.default.fileExists(atPath: "\(applications)/TestApp.app"))
    }

    @Test func aZipWithEntriesOutsideItsFolderWritesNothingThere() throws {
        defer { try? FileManager.default.removeItem(atPath: root) }
        // Made by hand (ditto wouldn't): an entry named ../../escaped beside the app.
        try makeApp(at: "\(root)/Build/TestApp.app", version: "2")
        let zipPath = "\(container)/slip.zip"
        let script = """
            import sys, zipfile, os
            z = zipfile.ZipFile(sys.argv[1], "w")
            for base, _, names in os.walk(sys.argv[2]):
                for name in names:
                    full = os.path.join(base, name)
                    z.write(full, os.path.relpath(full, os.path.dirname(sys.argv[2])))
            z.writestr("../../escaped", "x")
            z.close()
            """
        try run("/usr/bin/python3", ["-I", "-c", script, zipPath, "\(root)/Build/TestApp.app"])
        _ = install((zipPath, try files.sha256(ofFile: zipPath)))
        #expect(!FileManager.default.fileExists(atPath: "\(root)/escaped"))
        #expect(!FileManager.default.fileExists(atPath: "\(root)/Service/escaped"))
    }

    @Test func refusesAFIFOAndALinkOutOfTheFoldersWithoutWaiting() throws {
        defer { try? FileManager.default.removeItem(atPath: root) }
        let fifo = "\(container)/fifo.zip"
        #expect(mkfifo(fifo, 0o600) == 0)
        #expect(install((fifo, String(repeating: "ab", count: 32))).refusal?.code == .noFile)
        let outside = "\(root)/outside.zip"
        try Data("x".utf8).write(to: URL(fileURLWithPath: outside))
        try FileManager.default.createSymbolicLink(atPath: "\(container)/link.zip", withDestinationPath: outside)
        #expect(install(("\(container)/link.zip", try files.sha256(ofFile: outside))).refusal?.code == .outsideFolders)
    }

    @Test func refusesABuildThatUnpacksTooLarge() throws {
        defer { try? FileManager.default.removeItem(atPath: root) }
        let zip = try zip(try makeApp(at: "\(root)/Build/TestApp.app", version: "2", extra: 2_000_000))
        var small = policy
        small.maxUnpackedBytes = 1_000_000
        #expect(install(zip, policy: small).refusal?.code == .tooLarge)
        small.maxZipBytes = 10
        #expect(install(zip, policy: small).refusal?.code == .tooLarge)
    }

    @Test func aZipThatSaysLessThanItHoldsIsStoppedAsItUnpacks() throws {
        defer { try? FileManager.default.removeItem(atPath: root) }
        // An app with 400 MB of zeros, its zip's headers rewritten to say every entry is 1000 bytes.
        try makeApp(at: "\(root)/Build/TestApp.app", version: "2")
        try Data(count: 400_000_000).write(to: URL(fileURLWithPath: "\(root)/Build/TestApp.app/Contents/blob"))
        let zipPath = "\(container)/lying.zip"
        let script = """
            import sys, zipfile, os, struct
            z = zipfile.ZipFile(sys.argv[1], "w", zipfile.ZIP_DEFLATED)
            for base, _, names in os.walk(sys.argv[2]):
                for name in names:
                    full = os.path.join(base, name)
                    z.write(full, os.path.relpath(full, os.path.dirname(sys.argv[2])))
            z.close()
            data = bytearray(open(sys.argv[1], "rb").read())
            i = 0
            while True:
                i = data.find(b"PK\\x01\\x02", i)
                if i < 0: break
                struct.pack_into("<I", data, i + 24, 1000)
                local = struct.unpack_from("<I", data, i + 42)[0]
                struct.pack_into("<I", data, local + 22, 1000)
                i += 4
            open(sys.argv[1], "wb").write(data)
            """
        try run("/usr/bin/python3", ["-I", "-c", script, zipPath, "\(root)/Build/TestApp.app"])
        #expect((files.declaredSize(ofZip: zipPath) ?? 0) < 1_000_000, "the headers say little")
        var small = policy
        small.maxUnpackedBytes = 20_000_000
        let refusal = install((zipPath, try files.sha256(ofFile: zipPath)), policy: small).refusal
        #expect(refusal?.code == .tooLarge || refusal?.code == .unpackFailed, "\(String(describing: refusal))")
        #expect(!FileManager.default.fileExists(atPath: "\(applications)/TestApp.app"))
        // Nothing of it left behind in the service's folder.
        #expect(files.size(of: "\(root)/Service") < 50_000_000)
    }

    @Test func theNoteIsReadThroughTheServiceAndRemovedOnce() async throws {
        defer { try? FileManager.default.removeItem(atPath: root) }
        let handler = UpdateKitInstallHandler(policy: policy, files: files)
        let note = WatchNote(outcome: .restored, reason: "quit early", bundleID: "com.example.TestApp", executableSHA256: "ab",
                             at: Date(timeIntervalSince1970: 1_800_000_000))
        try MacWatchSystem(files: files).write(note.json, to: "\(root)/watch.json")
        func read(remove: Bool) async -> Data? {
            await withCheckedContinuation { continuation in handler.note(remove: remove) { continuation.resume(returning: $0) } }
        }
        #expect(await read(remove: false).flatMap(WatchNote.decoded) == note)
        #expect(await read(remove: true).flatMap(WatchNote.decoded) == note)
        #expect(await read(remove: false) == nil)
    }

    @Test func anAdHocServiceInstallsNothingButForTests() throws {
        defer { try? FileManager.default.removeItem(atPath: root) }
        let zip = try zip(try makeApp(at: "\(root)/Build/TestApp.app", version: "2"))
        for signing in [InstallPolicy.Signing.developerID, .team] {
            var signed = policy
            signed.signing = signing
            #expect(install(zip, policy: signed).refusal?.code == .badSignature)
        }
        // A build changed after it was signed (its executable), under the policy a test build of the service takes.
        let broken = try makeApp(at: "\(root)/Broken/TestApp.app", version: "3")
        let executable = try FileHandle(forWritingTo: URL(fileURLWithPath: "\(broken)/Contents/MacOS/TestApp"))
        try executable.seekToEnd()
        try executable.write(contentsOf: Data("changed".utf8))
        try executable.close()
        #expect(install(try self.zip(broken, as: "broken.zip")).refusal?.code == .badSignature)
    }

    @Test func theNoteIsNeverWrittenThroughALink() throws {
        defer { try? FileManager.default.removeItem(atPath: root) }
        let system = MacWatchSystem(files: files)
        try FileManager.default.createDirectory(atPath: "\(root)/Elsewhere", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: "\(root)/Notes", withDestinationPath: "\(root)/Elsewhere")
        #expect(throws: (any Error).self) { try system.write("x", to: "\(root)/Notes/note.json") }
        // A link put where the note goes: replaced by the note itself (renamed over it), what it points to untouched.
        try FileManager.default.createSymbolicLink(atPath: "\(root)/note.json", withDestinationPath: "\(root)/Elsewhere/target")
        try system.write("x", to: "\(root)/note.json")
        #expect(!FileManager.default.fileExists(atPath: "\(root)/Elsewhere/target"))
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: "\(root)/note.json")) == nil)
        #expect(system.read("\(root)/note.json") == "x")
        try system.write("x", to: "\(root)/plain.json")
        #expect(system.read("\(root)/plain.json") == "x")
    }
}
#endif
