import Foundation

/// What the install rules look at and do (BundleInstall): the Mac, outside the App Sandbox (MacBundleInstallSystem),
/// or a test's.
public protocol BundleInstallSystem {
    /// The service's own folder, where each install unpacks and its backup is kept: its alone (never another
    /// service's, never in /Applications).
    var ownFolder: String { get }
    /// `path` with every link resolved (realpath), nil when nothing is there.
    func resolvingLinks(_ path: String) -> String?
    /// Whether `path` (resolved) is a plain file.
    func isFile(_ path: String) -> Bool
    /// Whether `path` is a folder itself, not a link to one (lstat).
    func isRealFolder(_ path: String) -> Bool
    /// Whether anything is at `path`, not following a link.
    func exists(_ path: String) -> Bool
    /// When `path` was last changed, nil when nothing is there.
    func modified(_ path: String) -> Date?
    /// The file's SHA-256, lowercase hex.
    func sha256(ofFile path: String) throws -> String
    /// A new, empty folder in `ownFolder`.
    func makeFolder() throws -> String
    /// A folder made at `path` (its parent there already), owner-only.
    func createFolder(_ path: String) throws
    /// The zip's bytes copied into `folder` from one opening of it: never through a link, only a plain file of at most
    /// `maxBytes`, whose opened path is still inside one of `folders` (else `InstallRefusal` `.outsideFolders` or
    /// `.tooLarge`), with no extended attribute kept. The copy's path.
    func copy(zip: String, into folder: String, within folders: [String], maxBytes: Int) throws -> String
    /// The zip unpacked into `folder`, nothing quarantined (`ditto -x -k --noqtn`); `InstallRefusal` `.unpackTimedOut`
    /// when it ran longer than `timeLimit` seconds (and was stopped).
    func unpack(zip: String, into folder: String, timeLimit: TimeInterval) throws
    /// What the zip's directory says it unpacks to, nil when it can't be read (a zip that says nothing is refused).
    func declaredSize(ofZip zip: String) -> Int?
    /// The bytes of everything under `path`, links not followed.
    func size(of path: String) -> Int
    /// A folder's entries' names.
    func entries(of folder: String) -> [String]
    /// A value of an app's Contents/Info.plist on disk (a string), nil when it has none.
    func infoValue(_ key: String, ofApp path: String) -> String?
    /// Nil when the app's signature passes the check `signing` asks for (always Apple's anchor and the service's own
    /// team), else why not.
    func signatureRefusal(ofApp path: String, signing: InstallPolicy.Signing) -> String?
    /// Every `com.apple.quarantine` under `path` removed (the bundle and everything in it).
    func removeQuarantine(under path: String) throws
    /// `new` put at `destination` in one rename, swapped with what's there: where the replaced copy is now, nil when
    /// nothing was there (and then never over anything that appeared meanwhile). A failure leaves `destination` as it was.
    func swap(_ new: String, into destination: String) throws -> String?
    /// The app registered with LaunchServices (`lsregister -f`).
    func register(app path: String)
    /// The app forgotten by LaunchServices (`lsregister -u`), before it's removed.
    func unregister(app path: String)
    /// Whether a running process's executable is inside `path`.
    func isInUse(_ path: String) -> Bool
    func read(_ path: String) -> Data?
    /// `data` written to `path` whole.
    func write(_ data: Data, to path: String) throws
    /// A file or folder removed; never fails (what's left is left).
    func remove(_ path: String)
}
