#if !canImport(Darwin)
import Foundation
import Testing
import UpdateKit

/// What UpdateKit gives where there are no app groups or Darwin
/// notifications (Linux, and Isomer's headless host): the shared database
/// in a folder standing for the group's container, and the signal within
/// the process.
@Suite(.serialized)
struct LinuxSurfaceTests {
    @Test func theDatabaseIsInTheFolderNamed() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("group-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        setenv(AppGroupStore.containerVariable, folder.path, 1)
        defer { unsetenv(AppGroupStore.containerVariable) }

        let store = try AppGroupStore.appGroup("group.com.example.Distributor")

        #expect(store.fileURL.standardizedFileURL.path == folder.appendingPathComponent(AppGroupStore.fileName).standardizedFileURL.path)
        #expect(try await store.recordInstalled(bundleID: "com.example.App", version: "1.0", build: "1"))
        #expect(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    @Test func noGroupNamedIsAnError() {
        // A test runner's Info.plist names no group.
        #expect(throws: AppGroupStoreError.self) { try AppGroupStore.appGroup() }
    }

    @Test func aPostIsHeardInTheProcess() async throws {
        let signal = UpdateSignal(appGroup: "group.com.example.Distributor." + UUID().uuidString)
        let heard = Heard()
        let listening = Task {
            for await _ in signal.changes() { await heard.mark(); return }
        }
        defer { listening.cancel() }
        // Posted until the listener, which starts on its own task, hears it.
        var tries = 0
        while !(await heard.yes), tries < 200 {
            signal.post()
            try await Task.sleep(nanoseconds: 10_000_000)
            tries += 1
        }
        #expect(await heard.yes)
    }

    @Test func anotherNameIsNotHeard() async throws {
        let mine = UpdateSignal(appGroup: "group.mine." + UUID().uuidString)
        let other = UpdateSignal(appGroup: "group.other." + UUID().uuidString)
        let heard = Heard()
        let listening = Task {
            for await _ in mine.changes() { await heard.mark(); return }
        }
        defer { listening.cancel() }
        for _ in 0..<20 {
            other.post()
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(!(await heard.yes))
    }
}

/// Whether a listener heard the signal.
private actor Heard {
    private(set) var yes = false
    func mark() { yes = true }
}
#endif
