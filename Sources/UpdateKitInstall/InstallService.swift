#if os(macOS)
import Foundation

/// The installer service's XPC interface, shared by every app that embeds one: each value JSON (the Codable types of
/// this module), each reply an `InstallReply`'s JSON. The service's policy is its own, never the caller's.
@objc public protocol UpdateKitInstallXPC {
    /// A `BundleInstallRequest`: replies with an `InstallReply<InstallResult>`.
    func install(_ request: Data, reply: @escaping @Sendable (Data) -> Void)
    /// A `RestoreRequest`: replies with an `InstallReply<Bool>` (true once restored).
    func restore(_ request: Data, reply: @escaping @Sendable (Data) -> Void)
    /// A backup's path: replies whether it was one of the service's (then it's discarded).
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

/// What `restore` is asked: the install's result to undo.
public struct RestoreRequest: Codable, Sendable, Equatable {
    public var backup: String
    public var destination: String
    public var installedExecutableSHA256: String
    public var bundleID: String

    public init(backup: String, destination: String, installedExecutableSHA256: String, bundleID: String) {
        self.backup = backup
        self.destination = destination
        self.installedExecutableSHA256 = installedExecutableSHA256
        self.bundleID = bundleID
    }
}

/// The service's side: `UpdateKitInstallXPC` carried out with its own policy. One call at a time (an install's swap
/// and a sweep never overlap).
public final class UpdateKitInstallHandler: NSObject, UpdateKitInstallXPC, @unchecked Sendable {
    public let policy: InstallPolicy
    let files: MacBundleInstallSystem
    private let queue = DispatchQueue(label: "update-kit-install")

    public init(policy: InstallPolicy, files: MacBundleInstallSystem = MacBundleInstallSystem()) {
        self.policy = policy
        self.files = files
    }

    /// The interface to export (`NSXPCConnection.exportedInterface`) and to ask for (`remoteObjectInterface`).
    public static var interface: NSXPCInterface { NSXPCInterface(with: UpdateKitInstallXPC.self) }

    public func install(_ request: Data, reply: @escaping @Sendable (Data) -> Void) {
        queue.async { [self] in
            let result: Result<InstallResult, InstallRefusal> = decode(BundleInstallRequest.self, request).flatMap {
                BundleInstall.install($0, policy: policy, system: files)
            }
            reply(Self.encode(InstallReply(result)))
        }
    }

    public func restore(_ request: Data, reply: @escaping @Sendable (Data) -> Void) {
        queue.async { [self] in
            let result: Result<Bool, InstallRefusal> = decode(RestoreRequest.self, request).flatMap {
                BundleInstall.restore(backup: $0.backup, destination: $0.destination, installedExecutableSHA256: $0.installedExecutableSHA256,
                                      bundleID: $0.bundleID, policy: policy, system: files).map { true }
            }
            reply(Self.encode(InstallReply(result)))
        }
    }

    public func discard(_ backup: String, reply: @escaping @Sendable (Bool) -> Void) {
        queue.async { [self] in reply(BundleInstall.discard(backup: backup, system: files)) }
    }

    public func watch(_ watch: Data, reply: @escaping @Sendable (Data) -> Void) {
        queue.async { [self] in
            let result: Result<Bool, InstallRefusal> = decode(StayUpWatch.self, watch)
                .flatMap { StayUpWatcher.checked($0, policy: policy, files: files) }
                .flatMap { StayUpWatchLauncher.start($0, files: files).map { true } }
            reply(Self.encode(InstallReply(result)))
        }
    }

    func decode<Value: Decodable>(_ type: Value.Type, _ data: Data) -> Result<Value, InstallRefusal> {
        do { return .success(try JSONDecoder().decode(type, from: data)) } catch {
            return .failure(InstallRefusal(.unreadable, "The installer couldn't read what it was asked."))
        }
    }

    static func encode<Value: Encodable>(_ value: Value) -> Data { (try? JSONEncoder().encode(value)) ?? Data() }
}

/// The app's side: the service by its name, each call async.
public struct UpdateKitInstallClient: Sendable {
    public let serviceName: String

    public init(serviceName: String) {
        self.serviceName = serviceName
    }

    public func install(_ request: BundleInstallRequest) async -> Result<InstallResult, InstallRefusal> {
        await call { proxy, done in proxy.install(Self.encode(request), reply: done) }
    }

    public func restore(_ request: RestoreRequest) async -> Result<Bool, InstallRefusal> {
        await call { proxy, done in proxy.restore(Self.encode(request), reply: done) }
    }

    public func discard(backup: String) async -> Bool {
        let connection = connect()
        defer { connection.invalidate() }
        return await withCheckedContinuation { continuation in
            let once = Once(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in once.resume(false) } as? UpdateKitInstallXPC
            guard let proxy else { return once.resume(false) }
            proxy.discard(backup) { once.resume($0) }
        }
    }

    /// Starts the watcher; the app quits next (its pid is the watch's `quittingPID`).
    public func watch(_ watch: StayUpWatch) async -> Result<Bool, InstallRefusal> {
        await call { proxy, done in proxy.watch(Self.encode(watch), reply: done) }
    }

    func connect() -> NSXPCConnection {
        let connection = NSXPCConnection(serviceName: serviceName)
        connection.remoteObjectInterface = UpdateKitInstallHandler.interface
        connection.resume()
        return connection
    }

    func call<Value: Codable & Sendable>(_ send: (UpdateKitInstallXPC, @escaping @Sendable (Data) -> Void) -> Void) async
        -> Result<Value, InstallRefusal> {
        let connection = connect()
        defer { connection.invalidate() }
        let lost = InstallRefusal(.unreadable, "The installer couldn't be reached.")
        let data: Data? = await withCheckedContinuation { continuation in
            let once = Once<Data?>(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in once.resume(nil) } as? UpdateKitInstallXPC
            guard let proxy else { return once.resume(nil) }
            send(proxy) { once.resume($0) }
        }
        guard let data, let reply = try? JSONDecoder().decode(InstallReply<Value>.self, from: data) else { return .failure(lost) }
        return reply.result
    }

    static func encode<Value: Encodable>(_ value: Value) -> Data { (try? JSONEncoder().encode(value)) ?? Data() }

    /// A continuation resumed once: by the reply, or by the connection's failing, whichever comes first.
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
