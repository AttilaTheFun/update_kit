import Foundation

/// GitHub's answer to a `ReleaseRequest`, after any redirect: its status,
/// headers and body.
public struct ReleaseAnswer: Sendable, Equatable {
    public var status: Int
    public var headers: [String: String]
    public var data: Data

    public init(status: Int, headers: [String: String] = [:], data: Data = Data()) {
        self.status = status
        self.headers = headers
        self.data = data
    }

    /// A header's value, by its name in any case.
    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}
