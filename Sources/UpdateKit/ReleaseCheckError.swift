import Foundation

/// Why a direct check of an app's releases failed. Retried at the next
/// check; nothing is shown.
public enum ReleaseCheckError: Error, Sendable, Equatable {
    /// GitHub answered a request with a status other than success (or, for
    /// the releases, not modified): 401 for a token it refused, 404 for a
    /// repository it doesn't show the token's holder.
    case answered(status: Int, url: URL)
    /// The answer was not HTTP's.
    case notHTTP
    /// The releases' answer could not be read.
    case unreadableReleases
}
