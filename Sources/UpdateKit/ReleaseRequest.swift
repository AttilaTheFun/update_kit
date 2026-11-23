import Foundation

/// A request of GitHub's API, as a `ReleaseChecker` sends it through its
/// transport: a GET of the URL with these headers.
public struct ReleaseRequest: Sendable, Equatable {
    public var url: URL
    public var headers: [String: String]

    public init(url: URL, headers: [String: String]) {
        self.url = url
        self.headers = headers
    }
}
