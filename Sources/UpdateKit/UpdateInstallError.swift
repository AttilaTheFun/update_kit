/// Why an update could not be installed.
public enum UpdateInstallError: Error, Sendable, Equatable, CustomStringConvertible {
    /// Applications said of no install link for it.
    case noInstallURL
    /// The system did not take the install link.
    case installLinkRefused
    /// No Applications on this Mac to ask.
    case applicationsNotInstalled
    /// `AppUpdates.start()` hasn't run, or found no app group.
    case notStarted

    public var description: String {
        switch self {
        case .noInstallURL: return "Applications has no install link for this build yet"
        case .installLinkRefused: return "The system did not open the build's install link"
        case .applicationsNotInstalled: return "Applications is not installed on this Mac"
        case .notStarted: return "AppUpdates.start() hasn't run, or found no app group"
        }
    }
}
