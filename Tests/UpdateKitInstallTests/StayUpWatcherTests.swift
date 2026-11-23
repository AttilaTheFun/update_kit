import Foundation
import Testing
@testable import UpdateKitInstall

/// The watcher's Mac: a clock its sleeping moves, processes that live until a time, and what opening the new build
/// starts (and when it answers).
final class FakeWatchMac: WatchSystem {
    let mac: FakeInstallMac
    var files: any BundleInstallSystem { mac }
    var clock = Date(timeIntervalSince1970: 2_000_000)
    let ownPID: Int32 = 4242
    /// Live processes: until when (nil: for good).
    var processes: [Int32: Date?] = [:]
    var executables: [Int32: String] = [:]
    var texts: [String: String] = [:]
    var terminated: [Int32] = []
    var opened: [String] = []
    /// What opening the destination starts: a process living this long (nil: never starts; .infinity: for good).
    var newBuildLives: TimeInterval? = .infinity
    /// When it first answers, after it starts (nil: never).
    var answersAfter: TimeInterval? = 5
    var listener: Int32?
    let newPID: Int32 = 500
    var started: Date?

    init(_ mac: FakeInstallMac) { self.mac = mac }

    func now() -> Date { clock }
    func sleep(_ seconds: TimeInterval) { clock = clock.addingTimeInterval(seconds) }

    func isAlive(_ pid: Int32) -> Bool {
        guard let until = processes[pid] else { return false }
        return until.map { clock < $0 } ?? true
    }

    func terminate(_ pid: Int32) {
        terminated.append(pid)
        processes[pid] = nil
    }

    func read(_ path: String) -> String? { texts[path] }
    func write(_ text: String, to path: String) throws { texts[path] = text }
    func remove(_ path: String) { texts[path] = nil }

    func open(app path: String) -> Bool {
        opened.append(path)
        // The first opening starts the new build; a later one (after a restore) the earlier.
        guard opened.count == 1, let lives = newBuildLives else { return true }
        if lives == .infinity { processes[newPID] = .some(nil) } else { processes[newPID] = .some(clock.addingTimeInterval(lives)) }
        executables[newPID] = "\(path)/Contents/MacOS/App"
        started = clock
        return true
    }

    func pids(runningExecutable path: String) -> [Int32] {
        executables.filter { $0.value == path && isAlive($0.key) }.map(\.key)
    }

    func answers(_ url: URL) -> Bool {
        guard let started, let answersAfter else { return false }
        return clock >= started.addingTimeInterval(answersAfter)
    }

    func listenerPID(of url: URL) -> Int32? { listener }
}

let lockPath = "\(group)/relaunch-watch.lock"
let notePath = "\(group)/update-note.json"

/// The app's 1.0 replaced by the new build, its backup kept, and the app (pid 300) quitting.
func installedAndQuitting() throws -> (FakeWatchMac, StayUpWatch) {
    let mac = macWithDownload()
    let result = try #require(install(mac).value)
    let system = FakeWatchMac(mac)
    mac.folders[group] = system.clock
    system.processes[300] = system.clock.addingTimeInterval(3)
    let watch = StayUpWatch(install: result, bundleID: "com.example.App", quittingPID: 300, lockPath: lockPath, notePath: notePath,
                            policy: policy)
    return (system, watch)
}

@Suite struct StayUpWatcherTests {
    @Test func aBuildThatStaysUpKeepsItsPlaceAndDropsTheBackup() throws {
        let (system, watch) = try installedAndQuitting()
        let note = StayUpWatcher.run(watch, system: system)
        #expect(note.outcome == .stayedUp)
        // Opened only once the app had quit, then watched its 120 seconds.
        let started = try #require(system.started)
        #expect(started >= Date(timeIntervalSince1970: 2_000_003))
        #expect(system.clock >= started.addingTimeInterval(120))
        let backup = try #require(watch.install.backup)
        #expect(system.mac.apps[backup] == nil)
        #expect(system.mac.apps["/Applications/App.app"]?.build == newBuild)
        // The note written, the lock given up.
        #expect(system.texts[notePath]?.contains("\"stayedUp\"") == true)
        #expect(system.texts[lockPath] == nil)
    }

    @Test func aBuildThatQuitsEarlyIsReplacedByTheEarlierOne() throws {
        let (system, watch) = try installedAndQuitting()
        system.newBuildLives = 30
        let note = StayUpWatcher.run(watch, system: system)
        #expect(note.outcome == .restored)
        #expect(note.reason?.contains("quit within 120 seconds") == true)
        #expect(system.mac.apps["/Applications/App.app"]?.build != newBuild)
        // Opened again: the earlier build.
        #expect(system.opened == ["/Applications/App.app", "/Applications/App.app"])
    }

    @Test func aBuildThatNeverStartsIsReplaced() throws {
        let (system, watch) = try installedAndQuitting()
        system.newBuildLives = nil
        let note = StayUpWatcher.run(watch, system: system)
        #expect(note.outcome == .restored)
        #expect(note.reason?.contains("didn't start within 30 seconds") == true)
    }

    @Test func aServerMustAnswerItsHealthURLFirst() throws {
        var (system, watch) = try installedAndQuitting()
        watch.healthURL = URL(string: "http://127.0.0.1:7433/api/hello")
        system.answersAfter = 20
        #expect(StayUpWatcher.run(watch, system: system).outcome == .stayedUp)
        // 20 seconds to answer, then 120 up.
        let started = try #require(system.started)
        #expect(system.clock >= started.addingTimeInterval(140))

        (system, watch) = try installedAndQuitting()
        watch.healthURL = URL(string: "http://127.0.0.1:7433/api/hello")
        watch.firstAnswerSeconds = 60
        system.answersAfter = nil
        let note = StayUpWatcher.run(watch, system: system)
        #expect(note.outcome == .restored)
        #expect(note.reason?.contains("didn't answer within 60 seconds") == true)
        // The new build's process ended before the earlier one is put back.
        #expect(system.terminated == [system.newPID])
    }

    @Test func anAnswerFromAnotherProcessDoesntCount() throws {
        let (system, base) = try installedAndQuitting()
        var watch = base
        watch.healthURL = URL(string: "http://127.0.0.1:7433/api/hello")
        watch.listenerMustBeWatched = true
        watch.firstAnswerSeconds = 30
        system.answersAfter = 0
        // The old process still holds the port.
        system.listener = 300
        #expect(StayUpWatcher.run(watch, system: system).outcome == .restored)
    }

    @Test func aRestoreRefusedSaysBothWhys() throws {
        let (system, watch) = try installedAndQuitting()
        system.newBuildLives = 10
        // Another build put in place meanwhile: never undone.
        system.mac.apps["/Applications/App.app"]?.build = String(repeating: "44", count: 32)
        let note = StayUpWatcher.run(watch, system: system)
        #expect(note.outcome == .restoreFailed)
        #expect(note.reason?.contains("quit within") == true)
        #expect(note.reason?.contains("isn't the build this install put there") == true)
    }

    @Test func theLockCountsOnlyWhileItsHolderLivesAndIsTakenFromALiveOne() throws {
        let (system, _) = try installedAndQuitting()
        // A stale line: nobody holds it.
        system.texts[lockPath] = "77 1999000\n"
        #expect(WatchLock.holder(lockPath, system: system) == nil)
        // A live holder is sent SIGTERM, and the line is this watcher's.
        system.processes[77] = .some(nil)
        #expect(WatchLock.holder(lockPath, system: system)?.pid == 77)
        try WatchLock.take(lockPath, system: system)
        #expect(system.terminated == [77])
        #expect(system.texts[lockPath] == "4242 2000000\n")
        // Released only while it's still its own.
        system.texts[lockPath] = "78 2000001\n"
        WatchLock.release(lockPath, system: system)
        #expect(system.texts[lockPath] == "78 2000001\n")
    }

    @Test func theServiceUsesItsOwnPolicyAndWritesOnlyInItsFolders() throws {
        let (system, base) = try installedAndQuitting()
        var watch = base
        // What the app sent as policy is replaced by the service's.
        watch.policy = InstallPolicy(bundleIDPrefix: "com", zipFolders: ["/"])
        #expect(StayUpWatcher.checked(watch, policy: policy, files: system.mac).value?.policy == policy)
        watch.notePath = "\(home)/.zshrc"
        #expect(StayUpWatcher.checked(watch, policy: policy, files: system.mac).refusal?.code == .outsideFolders)
        watch = base
        watch.bundleID = "com.example.Other"
        #expect(StayUpWatcher.checked(watch, policy: policy, files: system.mac).refusal?.code == .notInstallable)
        watch = base
        watch.install.destination = "/Users/someone/App.app"
        #expect(StayUpWatcher.checked(watch, policy: policy, files: system.mac).refusal?.code == .badName)
    }
}
