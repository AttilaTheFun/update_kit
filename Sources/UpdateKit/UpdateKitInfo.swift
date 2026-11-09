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

    /// The main bundle's app group.
    public static var mainAppGroup: String? { appGroup(in: Bundle.main.infoDictionary) }
    /// The main bundle's distributor bundle ids.
    public static var mainApplicationsBundleIDs: [String] { applicationsBundleIDs(in: Bundle.main.infoDictionary) }
}
