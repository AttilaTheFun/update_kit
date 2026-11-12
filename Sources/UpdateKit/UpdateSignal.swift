import Foundation

#if canImport(Darwin)

/// A Darwin notification in the app group's name, which every process of
/// the group can post and hear: the database changed (Applications synced a
/// newer build, an app asked Applications to install one). It carries
/// nothing; whoever hears it reads the database. No URL schemes, no XPC.
public struct UpdateSignal: Sendable {
    public let name: String

    public init(appGroup: String) {
        name = appGroup + ".updates"
    }

    public func post() {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(name as CFString), nil, nil, true)
    }

    /// Each time it is posted (by any process, this one too), until the
    /// sequence is dropped.
    public func changes() -> AsyncStream<Void> {
        let name = self.name
        return AsyncStream { continuation in
            let observer = SignalObserver(continuation: continuation)
            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(observer).toOpaque(),
                                            { _, observer, _, _, _ in
                                                guard let observer else { return }
                                                Unmanaged<SignalObserver>.fromOpaque(observer).takeUnretainedValue().continuation.yield()
                                            }, name as CFString, nil, .deliverImmediately)
            // The observer lives as long as this closure, which the stream
            // keeps until it ends.
            continuation.onTermination = { _ in
                CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(observer).toOpaque(),
                                                   CFNotificationName(name as CFString), nil)
            }
        }
    }
}

/// What a Darwin notification's callback is handed: the stream to tell.
private final class SignalObserver: Sendable {
    let continuation: AsyncStream<Void>.Continuation

    init(continuation: AsyncStream<Void>.Continuation) {
        self.continuation = continuation
    }
}
#else
/// Where Darwin's notifications aren't (Linux, Windows, the web, Android):
/// the same signal within this process alone. Each `post()` tells every
/// stream of the same name in the process. Apps there run alone, so this is
/// what their tests and a headless build see.
public struct UpdateSignal: Sendable {
    public let name: String

    public init(appGroup: String) {
        name = appGroup + ".updates"
    }

    public func post() {
        SignalRegistry.shared.post(name)
    }

    /// Each time it is posted in this process, until the sequence is dropped.
    public func changes() -> AsyncStream<Void> {
        let name = self.name
        return AsyncStream { continuation in
            let token = SignalRegistry.shared.add(name, continuation)
            continuation.onTermination = { _ in SignalRegistry.shared.remove(name, token) }
        }
    }
}

/// The process's listeners, by signal name.
private final class SignalRegistry: @unchecked Sendable {
    static let shared = SignalRegistry()
    private let lock = NSLock()
    private var listeners: [String: [UUID: AsyncStream<Void>.Continuation]] = [:]

    func add(_ name: String, _ continuation: AsyncStream<Void>.Continuation) -> UUID {
        let token = UUID()
        lock.lock(); defer { lock.unlock() }
        listeners[name, default: [:]][token] = continuation
        return token
    }

    func remove(_ name: String, _ token: UUID) {
        lock.lock(); defer { lock.unlock() }
        listeners[name]?[token] = nil
    }

    func post(_ name: String) {
        lock.lock()
        let told = Array((listeners[name] ?? [:]).values)
        lock.unlock()
        for continuation in told { continuation.yield() }
    }
}
#endif
