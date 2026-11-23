import Foundation

/// What an app says of its distributor in its Info.plist, so the library
/// names no app group and no app of its own: the app group it shares with
/// the app that distributes it, and, on a Mac, that app's bundle ids.
///
///     <key>UpdateKitAppGroup</key>
///     <string>group.com.example.Distributor</string>
///     <key>UpdateKitApplicationsBundleIDs</key>
///     <array><string>com.example.Distributor</string></array>
///
/// The app's entitlements (and profile) grant the same group.
public enum UpdateKitInfo {
    /// The Info.plist key of the app group, a string.
    public static let appGroupKey = "UpdateKitAppGroup"
    /// The Info.plist key of the distributor's bundle ids on a Mac, an array
    /// of strings, the one to ask first first (whichever is installed is
    /// asked to install an update).
    public static let applicationsBundleIDsKey = "UpdateKitApplicationsBundleIDs"
    /// The Info.plist key, a Boolean, of an app that installs itself through
    /// its own unsandboxed installer service (docs/Installing.md): handed
    /// its build as the checked zip, never an unpacked bundle (one a
    /// sandboxed process unpacked won't open).
    public static let installsFromZipKey = "UpdateKitInstallsFromZip"

    /// The app group an Info.plist names; nil when it names none, or only a
    /// build variable no build filled in (`$(UPDATE_KIT_APP_GROUP)`).
    public static func appGroup(in info: [String: Any]?) -> String? {
        guard let group = (info?[appGroupKey] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !group.isEmpty,
              !group.contains("$(") else {
            return nil
        }
        return group
    }

    /// The distributor's bundle ids an Info.plist names; empty when it names
    /// none.
    public static func applicationsBundleIDs(in info: [String: Any]?) -> [String] {
        (info?[applicationsBundleIDsKey] as? [String] ?? []).filter { !$0.isEmpty }
    }

    /// Whether an Info.plist says the app takes its build as its zip.
    public static func installsFromZip(in info: [String: Any]?) -> Bool {
        info?[installsFromZipKey] as? Bool ?? false
    }

    /// The main bundle's app group.
    public static var mainAppGroup: String? { appGroup(in: Bundle.main.infoDictionary) }
    /// The main bundle's distributor bundle ids.
    public static var mainApplicationsBundleIDs: [String] { applicationsBundleIDs(in: Bundle.main.infoDictionary) }
    /// Whether the main bundle takes its build as its zip.
    public static var mainInstallsFromZip: Bool { installsFromZip(in: Bundle.main.infoDictionary) }
}
