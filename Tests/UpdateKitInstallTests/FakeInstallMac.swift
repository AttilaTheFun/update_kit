import Foundation
@testable import UpdateKitInstall

/// A Mac as the install rules see it (BundleInstallSystem): its files (each app with its Info.plist's values), the
/// zips' digests and what each unpacks to, the signatures that pass, what runs; every step done, in order.
final class FakeInstallMac: BundleInstallSystem {
    enum Step: Equatable {
        case copy(String)
        case unpack(String)
        case removeQuarantine(String)
        case swap(String, String)
        case register(String)
        case unregister(String)
        case remove(String)
    }

    struct App: Equatable {
        var bundleID: String
        var executable = "App"
        /// Its main executable's digest.
        var build = String(repeating: "11", count: 32)
    }

    let ownFolder = "/private/var/folders/xx/T/UpdateKitInstall"
    /// Paths that resolve to another (links).
    var links: [String: String] = [:]
    var files: Set<String> = []
    var apps: [String: App] = [:]
    var folders: [String: Date] = [:]
    var digests: [String: String] = [:]
    /// What each zip holds: its apps' names.
    var contents: [String: [(name: String, app: App)]] = [:]
    var badSignatures: Set<String> = []
    var running: [String] = []
    var steps: [Step] = []
    var unpackFails: InstallRefusal?
    /// Run once the zip is copied: the app changing it then (which the copy doesn't see).
    var afterCopy: (FakeInstallMac) -> Void = { _ in }
    var made = 0

    var folder: String { "\(ownFolder)/\(made)" }
    var copied: String { "\(folder)/build.zip" }

    func resolvingLinks(_ path: String) -> String? {
        var resolved = path
        for (link, destination) in links where resolved == link || resolved.hasPrefix(link + "/") {
            resolved = destination + String(resolved.dropFirst(link.count))
        }
        return exists(resolved) || files.contains { $0.hasPrefix(resolved + "/") } || apps.keys.contains { $0.hasPrefix(resolved + "/") }
            ? resolved : nil
    }

    func isFile(_ path: String) -> Bool {
        if files.contains(path) { return true }
        // An app's main executable.
        return apps.contains { path == "\($0.key)/Contents/MacOS/\($0.value.executable)" }
    }

    func exists(_ path: String) -> Bool { apps[path] != nil || files.contains(path) || folders[path] != nil || path == ownFolder }
    func modified(_ path: String) -> Date? { folders[path] }

    struct Unreadable: Error {}

    func sha256(ofFile path: String) throws -> String {
        if let digest = digests[path] { return digest }
        if let app = apps.first(where: { path == "\($0.key)/Contents/MacOS/\($0.value.executable)" }) { return app.value.build }
        throw Unreadable()
    }

    func makeFolder() throws -> String {
        made += 1
        folders[folder] = Date(timeIntervalSince1970: 1_000_000)
        return folder
    }

    func copy(zip: String, into folder: String) throws -> String {
        steps.append(.copy(zip))
        let copy = "\(folder)/build.zip"
        files.insert(copy)
        digests[copy] = digests[zip]
        contents[copy] = contents[zip]
        afterCopy(self)
        return copy
    }

    func unpack(zip: String, into folder: String, timeLimit: TimeInterval) throws {
        steps.append(.unpack(zip))
        if let unpackFails { throw unpackFails }
        for entry in contents[zip] ?? [] { apps["\(folder)/\(entry.name)"] = entry.app }
    }

    func entries(of folder: String) -> [String] {
        let children = Array(apps.keys) + Array(files) + Array(folders.keys)
        return Set(children.filter { $0.hasPrefix(folder + "/") }.compactMap {
            $0.dropFirst(folder.count + 1).split(separator: "/").first.map(String.init)
        }).sorted()
    }

    func infoValue(_ key: String, ofApp path: String) -> String? {
        switch key {
        case "CFBundleIdentifier": return apps[path]?.bundleID
        case "CFBundleExecutable": return apps[path]?.executable
        default: return nil
        }
    }

    func signatureRefusal(ofApp path: String) -> String? {
        badSignatures.contains(path) ? "The build isn't signed with its team's Developer ID and notarized." : nil
    }

    func removeQuarantine(under path: String) throws { steps.append(.removeQuarantine(path)) }

    func swap(_ new: String, into destination: String) throws -> String? {
        steps.append(.swap(new, destination))
        let old = apps[destination]
        apps[destination] = apps[new]
        apps[new] = old
        return old == nil ? nil : new
    }

    func register(app path: String) { steps.append(.register(path)) }
    func unregister(app path: String) { steps.append(.unregister(path)) }
    func isInUse(_ path: String) -> Bool { running.contains { $0.hasPrefix(path + "/") } }

    func remove(_ path: String) {
        steps.append(.remove(path))
        apps = apps.filter { $0.key != path && !$0.key.hasPrefix(path + "/") }
        files = files.filter { $0 != path && !$0.hasPrefix(path + "/") }
        folders = folders.filter { $0.key != path && !$0.key.hasPrefix(path + "/") }
    }

    /// Whether anything was put in the applications folder.
    var swapped: Bool { steps.contains { if case .swap = $0 { return true } else { return false } } }
    var unpacked: Bool { steps.contains { if case .unpack = $0 { return true } else { return false } } }
    var removals: [String] { steps.compactMap { if case .remove(let path) = $0 { return path } else { return nil } } }
}

let home = "/Users/someone"
let container = "\(home)/Library/Containers/com.example.App/Data"
let group = "\(home)/Library/Group Containers/group.com.example.Distributor"
let downloadedZip = "\(container)/Library/Caches/Updates/1/app.zip"
let buildSHA = String(repeating: "ab", count: 32)
let newBuild = String(repeating: "22", count: 32)
let policy = InstallPolicy(bundleIDPrefix: "com.example.App", zipFolders: [container, group], earlierIDSuffixes: [".Beta"])
let now = Date(timeIntervalSince1970: 1_000_100)

/// A Mac with the app's 1.0 installed and its next build downloaded into its container.
func macWithDownload() -> FakeInstallMac {
    let mac = FakeInstallMac()
    mac.files = [downloadedZip]
    mac.digests[downloadedZip] = buildSHA
    mac.contents[downloadedZip] = [(name: "App.app", app: .init(bundleID: "com.example.App", build: newBuild))]
    mac.apps["/Applications/App.app"] = .init(bundleID: "com.example.App")
    return mac
}

func install(_ mac: FakeInstallMac, zip: String = downloadedZip, bundleID: String = "com.example.App", sha256: String = buildSHA,
             name: String = "App", policy: InstallPolicy = policy) -> Result<InstallResult, InstallRefusal> {
    BundleInstall.install(BundleInstallRequest(zipPath: zip, bundleID: bundleID, sha256: sha256, name: name), policy: policy,
                          system: mac, now: now)
}

extension Result {
    var refusal: Failure? { if case .failure(let failure) = self { return failure } else { return nil } }
    var value: Success? { if case .success(let value) = self { return value } else { return nil } }
}
