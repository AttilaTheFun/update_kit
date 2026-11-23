#if os(macOS)
import Foundation

/// The installer service's XPC interface, shared by every app that embeds one: each value JSON (the Codable types of
/// this module), each reply an `InstallReply`'s JSON. The service's policy is its own, never the caller's.
@objc public protocol UpdateKitInstallXPC {
    /// A `BundleInstallRequest`: replies with an `InstallReply<InstallResult>`.
    func install(_ request: Data, reply: @escaping @Sendable (Data) -> Void)
    /// A backup's id (`InstallResult.backup`): replies with an `InstallReply<Bool>` (true once it's back).
    func restore(_ backup: String, reply: @escaping @Sendable (Data) -> Void)
    /// A backup's id: replies whether it was one of the service's (then it's discarded).
    func discard(_ backup: String, reply: @escaping @Sendable (Bool) -> Void)
    /// A `StayUpWatch`: replies with an `InstallReply<Bool>` (true once the watcher is started).
    func watch(_ watch: Data, reply: @escaping @Sendable (Data) -> Void)
}

/// A reply: the value, or the refusal.
public struct InstallReply<Value: Codable & Sendable>: Codable, Sendable {
    public var value: Value?
    public var refusal: InstallRefusal?

    public init(_ result: Result<Value, InstallRefusal>) {
        switch result {
        case .success(let value): self.value = value; refusal = nil
        case .failure(let failure): value = nil; refusal = failure
        }
    }

    public var result: Result<Value, InstallRefusal> {
        if let value { return .success(value) }
        return .failure(refusal ?? InstallRefusal(.unreadable, "The installer's reply can't be read."))
    }
}

/// An installer service's `main`: a watcher run when it's started as one (StayUpWatchLauncher), else the XPC
/// listener, taking connections only from code that meets `clientRequirement` (by default the app the service is
/// in: its bundle id, Apple's anchor and the service's own team), each served by a handler with `policy`. Never
/// returns.
public enum UpdateKitInstallService {
    public static func main(policy: InstallPolicy, files: MacBundleInstallSystem = MacBundleInstallSystem(),
                            clientRequirement: String? = nil) -> Never {
        StayUpWatchLauncher.runIfAsked(policy: policy, files: files)
        let delegate = Listening(handler: UpdateKitInstallHandler(policy: policy, files: files),
                                 requirement: clientRequirement ?? defaultRequirement(policy: policy))
        let listener = NSXPCListener.service()
        listener.delegate = delegate
        listener.resume()
        // NSXPCListener.service()'s resume doesn't return.
        exit(0)
    }

    /// The app around the service, signed by Apple's chain and the service's team; nil (no connection taken) when
    /// either can't be read. An ad hoc test build's (`adHocForTests`, in a debug build) names the app alone.
    static func defaultRequirement(policy: InstallPolicy) -> String? {
        guard let host = MacBundleInstallSystem.enclosingApp(), let identifier = Bundle(url: host)?.bundleIdentifier,
              !identifier.contains("\"") else { return nil }
        if let team = MacBundleInstallSystem.ownTeam {
            return "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\""
        }
        #if DEBUG
        if policy.signing == .adHocForTests { return "identifier \"\(identifier)\"" }
        #endif
        return nil
    }

    final class Listening: NSObject, NSXPCListenerDelegate {
        let handler: UpdateKitInstallHandler
        let requirement: String?

        init(handler: UpdateKitInstallHandler, requirement: String?) {
            self.handler = handler
            self.requirement = requirement
        }

        func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
            guard let requirement else { return false }
            // Checked by the system on every message, by the caller's audit token.
            connection.setCodeSigningRequirement(requirement)
            connection.exportedInterface = UpdateKitInstallHandler.interface
            connection.exportedObject = handler
            connection.resume()
            return true
        }
    }
}

/// The service's side: `UpdateKitInstallXPC` carried out with its own policy, one call at a time (an install's swap,
/// a restore and a sweep never overlap), each on a thread of its own: an unpacking may take minutes, which no Dispatch
/// worker shared with the rest of the process is kept waiting for.
public final class UpdateKitInstallHandler: NSObject, UpdateKitInstallXPC, @unchecked Sendable {
    public let policy: InstallPolicy
    let files: MacBundleInstallSystem
    private let oneAtATime = NSLock()

    /// `work` on a thread of its own, once no other call's is running.
    private func serially(_ work: @escaping @Sendable () -> Void) {
        let lock = oneAtATime
        Thread.detachNewThread {
            lock.lock()
            defer { lock.unlock() }
            work()
        }
    }

    public init(policy: InstallPolicy, files: MacBundleInstallSystem = MacBundleInstallSystem()) {
        self.policy = policy
        self.files = files
    }

    /// The interface to export (`NSXPCConnection.exportedInterface`) and to ask for (`remoteObjectInterface`).
    public static var interface: NSXPCInterface { NSXPCInterface(with: UpdateKitInstallXPC.self) }

    public func install(_ request: Data, reply: @escaping @Sendable (Data) -> Void) {
        serially { [self] in
            let result: Result<InstallResult, InstallRefusal> = decode(BundleInstallRequest.self, request).flatMap { request in
                // Nothing installed under a watch: it would be undone, or undo the watch's restore.
                if let lock = policy.watchLockPath, WatchLock.holder(lock, system: MacWatchSystem(files: files)) != nil {
                    return .failure(InstallRefusal(.watchInProgress, "An update is being watched: try again once it's done."))
                }
                return BundleInstall.install(request, policy: policy, system: files)
            }
            reply(Self.encode(InstallReply(result)))
        }
    }

    public func restore(_ backup: String, reply: @escaping @Sendable (Data) -> Void) {
        serially { [self] in
            reply(Self.encode(InstallReply(BundleInstall.restore(backup: backup, policy: policy, system: files).map { true })))
        }
    }

    public func discard(_ backup: String, reply: @escaping @Sendable (Bool) -> Void) {
        serially { [self] in reply(BundleInstall.discard(backup: backup, system: files)) }
    }

    public func watch(_ watch: Data, reply: @escaping @Sendable (Data) -> Void) {
        serially { [self] in
            let result: Result<Bool, InstallRefusal> = decode(StayUpWatch.self, watch)
                .flatMap { StayUpWatcher.checked($0, policy: policy, files: files) }
                .flatMap { StayUpWatchLauncher.start($0, policy: policy, files: files).map { true } }
            reply(Self.encode(InstallReply(result)))
        }
    }

    func decode<Value: Decodable>(_ type: Value.Type, _ data: Data) -> Result<Value, InstallRefusal> {
        do { return .success(try JSONDecoder().decode(type, from: data)) } catch {
            return .failure(InstallRefusal(.badRequest, "The installer couldn't read what it was asked."))
        }
    }

    static func encode<Value: Encodable>(_ value: Value) -> Data { (try? JSONEncoder().encode(value)) ?? Data() }
}

/// The app's side: the service by its name, each call async, given up on (`unreachable`) after `timeLimit` seconds.
public struct UpdateKitInstallClient: Sendable {
    public let serviceName: String
    /// A large build's copy, check and unpacking take a while.
    public let timeLimit: TimeInterval

    public init(serviceName: String, timeLimit: TimeInterval = 900) {
        self.serviceName = serviceName
        self.timeLimit = timeLimit
    }

    public func install(_ request: BundleInstallRequest) async -> Result<InstallResult, InstallRefusal> {
        await call { proxy, done in proxy.install(Self.encode(request), reply: done) }
    }

    public func restore(backup: String) async -> Result<Bool, InstallRefusal> {
        await call { proxy, done in proxy.restore(backup, reply: done) }
    }

    public func discard(backup: String) async -> Bool {
        let result: Result<Bool, InstallRefusal> = await call { proxy, done in
            proxy.discard(backup) { discarded in done(UpdateKitInstallHandler.encode(InstallReply(.success(discarded)))) }
        }
        return (try? result.get()) ?? false
    }

    /// Starts the watcher. Quit the app only once it's started: a refused watch leaves nothing to reopen it.
    public func watch(_ watch: StayUpWatch) async -> Result<Bool, InstallRefusal> {
        await call { proxy, done in proxy.watch(Self.encode(watch), reply: done) }
    }

    func call<Value: Codable & Sendable>(_ send: (UpdateKitInstallXPC, @escaping @Sendable (Data) -> Void) -> Void) async
        -> Result<Value, InstallRefusal> {
        let connection = NSXPCConnection(serviceName: serviceName)
        connection.remoteObjectInterface = UpdateKitInstallHandler.interface
        connection.resume()
        defer { connection.invalidate() }
        let unreachable = InstallRefusal(.unreachable, "The installer couldn't be reached, or didn't answer.")
        let data: Data? = await withCheckedContinuation { continuation in
            let once = Once<Data?>(continuation)
            connection.invalidationHandler = { once.resume(nil) }
            connection.interruptionHandler = { once.resume(nil) }
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in once.resume(nil) } as? UpdateKitInstallXPC
            guard let proxy else { return once.resume(nil) }
            send(proxy) { once.resume($0) }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeLimit) { once.resume(nil) }
        }
        guard let data, let reply = try? JSONDecoder().decode(InstallReply<Value>.self, from: data) else { return .failure(unreachable) }
        return reply.result
    }

    static func encode<Value: Encodable>(_ value: Value) -> Data { (try? JSONEncoder().encode(value)) ?? Data() }

    /// A continuation resumed once: by the reply, the connection's failing or the time limit, whichever comes first.
    final class Once<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Value, Never>?

        init(_ continuation: CheckedContinuation<Value, Never>) {
            self.continuation = continuation
        }

        func resume(_ value: Value) {
            let continuation = lock.withLock { () -> CheckedContinuation<Value, Never>? in
                defer { self.continuation = nil }
                return self.continuation
            }
            continuation?.resume(returning: value)
        }
    }
}
#endif
