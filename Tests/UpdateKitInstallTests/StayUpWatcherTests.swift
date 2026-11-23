import Foundation
import Testing
@testable import UpdateKitInstall

/// The watcher's Mac: a clock its sleeping moves, processes that live until a time (and their executables), and what
/// opening the new build starts (and when it answers).
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
    var killed: [Int32] = []
    /// Processes that ignore SIGTERM.
    var stubborn: Set<Int32> = []
    var opened: [String] = []
    /// What opening the destination starts: a process living this long (nil: never starts; .infinity: for good).
    var newBuildLives: TimeInterval? = .infinity
    /// When it first answers, after it starts (nil: never).
    var answersAfter: TimeInterval? = 5
    var listeners: [Int32] = []
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
        if !stubborn.contains(pid) { processes[pid] = nil }
    }

    func kill(_ pid: Int32) {
        killed.append(pid)
        processes[pid] = nil
    }

    func executablePath(of pid: Int32) -> String? { executables[pid] }
    func read(_ path: String) -> String? { texts[path] }
    func write(_ text: String, to path: String) throws { texts[path] = text }
    func remove(_ path: String) { texts[path] = nil }

    func open(app path: String) -> Bool {
        opened.append(path)
        // Opening the new build starts it (once); the earlier build, put back, isn't watched.
        guard started == nil, mac.apps[path]?.build == newBuild, let lives = newBuildLives else { return true }
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

    func listenerPIDs(of url: URL) -> [Int32] { listeners }
}

/// The app's build 1 replaced by build 2, its backup kept, and the app (pid 300) quitting.
func installedAndQuitting() throws -> (FakeWatchMac, StayUpWatch) {
    let mac = macWithDownload()
    let result = try #require(install(mac).value)
    let system = FakeWatchMac(mac)
    system.processes[300] = system.clock.addingTimeInterval(3)
    return (system, StayUpWatch(install: result, bundleID: "com.example.App", quittingPID: 300))
}

@Suite struct StayUpWatcherTests {
    @Test func aBuildThatStaysUpKeepsItsPlaceAndDropsTheBackup() throws {
        let (system, watch) = try installedAndQuitting()
        let note = StayUpWatcher.run(watch, policy: policy, system: system)
        #expect(note.outcome == .stayedUp)
        // Opened only once the app had quit, then watched its 120 seconds.
        let started = try #require(system.started)
        #expect(started >= Date(timeIntervalSince1970: 2_000_003))
        #expect(system.clock >= started.addingTimeInterval(120))
        let backup = try #require(watch.install.backup)
        #expect(system.mac.folders["\(system.mac.ownFolder)/\(backup)"] == nil)
        #expect(system.mac.apps["/Applications/App.app"]?.build == newBuild)
        // The note written where the policy says, the lock given up.
        #expect(system.texts[notePath]?.contains("\"stayedUp\"") == true)
        #expect(system.texts[lockPath] == nil)
    }

    @Test func aBuildThatQuitsEarlyIsReplacedByTheEarlierOne() throws {
        let (system, watch) = try installedAndQuitting()
        system.newBuildLives = 30
        let note = StayUpWatcher.run(watch, policy: policy, system: system)
        #expect(note.outcome == .restored)
        #expect(note.reason?.contains("quit within 120 seconds") == true)
        #expect(system.mac.apps["/Applications/App.app"]?.version == "1")
        // Opened again: the earlier build.
        #expect(system.opened == ["/Applications/App.app", "/Applications/App.app"])
    }

    @Test func aBuildThatNeverStartsIsReplaced() throws {
        let (system, watch) = try installedAndQuitting()
        system.newBuildLives = nil
        let note = StayUpWatcher.run(watch, policy: policy, system: system)
        #expect(note.outcome == .restored)
        #expect(note.reason?.contains("didn't start within 30 seconds") == true)
    }

    @Test func anAppThatDoesntQuitHasItsUpdateUndoneNotOpenedOver() throws {
        let (system, watch) = try installedAndQuitting()
        system.processes[300] = .some(nil)
        let note = StayUpWatcher.run(watch, policy: policy, system: system)
        #expect(note.outcome == .restored)
        #expect(note.reason?.contains("didn't quit within 60 seconds") == true)
        #expect(system.started == nil)
    }

    @Test func aServerMustAnswerItsHealthURLFirst() throws {
        var (system, watch) = try installedAndQuitting()
        watch.healthURL = URL(string: "http://127.0.0.1:7433/api/hello")
        system.answersAfter = 20
        #expect(StayUpWatcher.run(watch, policy: policy, system: system).outcome == .stayedUp)
        let started = try #require(system.started)
        #expect(system.clock >= started.addingTimeInterval(140))

        (system, watch) = try installedAndQuitting()
        watch.healthURL = URL(string: "http://127.0.0.1:7433/api/hello")
        watch.firstAnswerSeconds = 60
        system.answersAfter = nil
        let note = StayUpWatcher.run(watch, policy: policy, system: system)
        #expect(note.outcome == .restored)
        #expect(note.reason?.contains("didn't answer within 60 seconds") == true)
        // The new build's process ended before the earlier one is put back.
        #expect(system.terminated == [system.newPID])
    }

    @Test func aProcessThatIgnoresSIGTERMIsKilledBeforeTheRestore() throws {
        let (system, base) = try installedAndQuitting()
        var watch = base
        watch.healthURL = URL(string: "http://127.0.0.1:7433/api/hello")
        watch.firstAnswerSeconds = 10
        system.answersAfter = nil
        system.stubborn = [system.newPID]
        #expect(StayUpWatcher.run(watch, policy: policy, system: system).outcome == .restored)
        #expect(system.terminated == [system.newPID])
        #expect(system.killed == [system.newPID])
    }

    @Test func anAnswerFromAnotherProcessDoesntCount() throws {
        var (system, watch) = try installedAndQuitting()
        watch.healthURL = URL(string: "http://127.0.0.1:7433/api/hello")
        watch.listenerMustBeWatched = true
        watch.firstAnswerSeconds = 30
        system.answersAfter = 0
        // The old process still holds the port.
        system.listeners = [300]
        #expect(StayUpWatcher.run(watch, policy: policy, system: system).outcome == .restored)
        // Among others, the watched one counts.
        (system, watch) = try installedAndQuitting()
        watch.healthURL = URL(string: "http://127.0.0.1:7433/api/hello")
        watch.listenerMustBeWatched = true
        system.answersAfter = 0
        system.listeners = [77, system.newPID]
        #expect(StayUpWatcher.run(watch, policy: policy, system: system).outcome == .stayedUp)
    }

    @Test func aRestoreRefusedSaysBothWhys() throws {
        let (system, watch) = try installedAndQuitting()
        system.newBuildLives = 10
        // Another build put in place meanwhile: never undone.
        system.mac.apps["/Applications/App.app"]?.build = String(repeating: "44", count: 32)
        let note = StayUpWatcher.run(watch, policy: policy, system: system)
        #expect(note.outcome == .restoreFailed)
        #expect(note.reason?.contains("The new build") == true)
        #expect(note.reason?.contains("isn't the build this install put there") == true)
    }

    @Test func theLockSignalsOnlyALiveWatcherOfTheServices() throws {
        let (system, _) = try installedAndQuitting()
        // A stale line, or pid 1: nobody holds it.
        system.texts[lockPath] = "77 1999000\n"
        #expect(WatchLock.holder(lockPath, system: system) == nil)
        system.texts[lockPath] = "1 1999000\n"
        system.processes[1] = .some(nil)
        #expect(WatchLock.holder(lockPath, system: system) == nil)
        // A forged line naming a live process that isn't a watcher (the app wrote it): taken over, nothing signalled.
        system.texts[lockPath] = "77 1999000\n"
        system.processes[77] = .some(nil)
        system.executables[77] = "/System/Applications/Finder.app/Contents/MacOS/Finder"
        try WatchLock.take(lockPath, ownFolder: system.mac.ownFolder, system: system)
        #expect(system.terminated.isEmpty)
        #expect(system.texts[lockPath] == "4242 2000000\n")
        // A live watcher of the service's: sent SIGTERM, then a second's wait.
        system.texts[lockPath] = "78 1999000\n"
        system.processes[78] = .some(nil)
        system.executables[78] = "\(system.mac.ownFolder)/9/Installer.xpc/Contents/MacOS/Installer"
        try WatchLock.take(lockPath, ownFolder: system.mac.ownFolder, system: system)
        #expect(system.terminated == [78])
        #expect(system.clock == Date(timeIntervalSince1970: 2_000_001))
        // Released only while it's still its own.
        system.texts[lockPath] = "79 2000001\n"
        WatchLock.release(lockPath, system: system)
        #expect(system.texts[lockPath] == "79 2000001\n")
    }

    @Test func theServiceWatchesOnlyItsAppsWithItsOwnLockAndNote() throws {
        let (system, base) = try installedAndQuitting()
        #expect(StayUpWatcher.checked(base, policy: policy, files: system.mac).value != nil)
        var none = policy
        none.watchLockPath = nil
        #expect(StayUpWatcher.checked(base, policy: none, files: system.mac).refusal?.code == .noWatches)
        var watch = base
        watch.bundleID = "com.example.Other"
        #expect(StayUpWatcher.checked(watch, policy: policy, files: system.mac).refusal?.code == .notInstallable)
        watch = base
        watch.install.destination = "/Users/someone/App.app"
        #expect(StayUpWatcher.checked(watch, policy: policy, files: system.mac).refusal?.code == .notInstallable)
        watch = base
        watch.install.backup = "../elsewhere"
        #expect(StayUpWatcher.checked(watch, policy: policy, files: system.mac).refusal?.code == .backupMissing)
        watch = base
        watch.healthURL = URL(string: "http://example.com/api/hello")
        #expect(StayUpWatcher.checked(watch, policy: policy, files: system.mac).refusal?.code == .badRequest)
        watch = base
        watch.quittingPID = 1
        #expect(StayUpWatcher.checked(watch, policy: policy, files: system.mac).refusal?.code == .badRequest)
    }
}
