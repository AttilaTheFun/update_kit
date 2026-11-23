import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// An app's direct check of its own releases (UpdateKit 0.19,
/// docs/DirectReleases.md): the newest build of it that GitHub's releases of
/// its repository carry, as their `builds.json` says, when it is newer than
/// the one running. It learns only: what it finds is written to the shared
/// database (`AppGroupStore.offerLatest`), nothing is shown or installed.
///
/// The releases are read with the ETag of the last answer, so an unchanged
/// list costs a 304; each `builds.json` is read once, by its asset's id.
/// Both are kept in memory, for the process.
public actor ReleaseChecker {
    /// Sends a request and returns GitHub's answer, after any redirect.
    public typealias Send = @Sendable (ReleaseRequest) async throws -> ReleaseAnswer
    /// The GitHub token to send, as the app's sign-in has it now; empty when
    /// signed out (nothing is checked).
    public typealias Token = @Sendable () async throws -> String

    /// The repository, `owner/name` (`UpdateKitInfo.releasesRepositoryKey`).
    public let repository: String
    private let token: Token
    private let send: Send
    /// The releases' last answer: its ETag and its body.
    private var etag: String?
    private var releasesBody: Data?
    /// Each `builds.json` read, by its asset's id.
    private var manifests: [Int: [Entry]] = [:]

    /// The releases read, at most this many, newest first.
    static let releasesRead = 10

    public init(repository: String, token: @escaping Token, send: @escaping Send = ReleaseChecker.urlSession) {
        self.repository = repository
        self.token = token
        self.send = send
    }

    /// The newest build of the app for the platform (`"ios"` or `"macos"`,
    /// as `builds.json` names them) in the releases its variant takes, when
    /// it is newer than the one running; else nil. Its install URL is nil:
    /// installing stays Applications' (or the app's own handler's).
    ///
    /// The releases taken by the installed variant (`InstalledApp.variant`,
    /// Production when it says none): Production, those published and not
    /// pre-releases; Beta, those published, pre-releases too; Alpha and
    /// AdHoc, any, drafts too (a proposal's). In them, the builds of the
    /// app's bundle id, platform and variant, signed, and not an
    /// experiment's (no `purpose`).
    public func check(app: InstalledApp, platform: String) async throws -> LatestBuild? {
        let token = try await token()
        guard !token.isEmpty else { return nil }
        let variant = app.variant ?? "Production"
        let releases = try await self.releases(token: token).filter { Self.takes($0, variant: variant) }
        var newest: AppVersion?
        for release in releases {
            guard let asset = release.assets.first(where: { $0.name == "builds.json" }) else { continue }
            for entry in try await manifest(asset.id, token: token)
            where entry.bundleID == app.bundleID && entry.platform == platform && entry.variant == variant
                && entry.signed != false && entry.purpose == nil {
                let version = AppVersion(entry.version, build: entry.buildNumber)
                if newest.map({ $0 < version }) ?? true { newest = version }
            }
        }
        guard let newest, app.appVersion < newest else { return nil }
        return LatestBuild(bundleID: app.bundleID, version: newest.version, build: newest.build, installURL: nil)
    }

    /// Whether a release is one the variant takes.
    static func takes(_ release: Release, variant: String) -> Bool {
        switch variant {
        case "Alpha", "AdHoc": true
        case "Beta": !release.draft
        // Production, and a variant not known: the published releases alone.
        default: !release.draft && !release.prerelease
        }
    }

    // MARK: GitHub

    private func releases(token: String) async throws -> [Release] {
        let url = URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=\(Self.releasesRead)")!
        var headers = Self.headers(token: token, accept: "application/vnd.github+json")
        if let etag, releasesBody != nil { headers["If-None-Match"] = etag }
        let answer = try await send(ReleaseRequest(url: url, headers: headers))
        let body: Data
        switch answer.status {
        case 304:
            guard let releasesBody else { throw ReleaseCheckError.answered(status: 304, url: url) }
            body = releasesBody
        case 200..<300:
            body = answer.data
            etag = answer.header("ETag")
            releasesBody = body
        default:
            throw ReleaseCheckError.answered(status: answer.status, url: url)
        }
        do {
            return try JSONDecoder().decode([Release].self, from: body)
        } catch {
            throw ReleaseCheckError.unreadableReleases
        }
    }

    /// A `builds.json`, read once: one that can't be decoded counts as
    /// listing nothing.
    private func manifest(_ id: Int, token: String) async throws -> [Entry] {
        if let kept = manifests[id] { return kept }
        let url = URL(string: "https://api.github.com/repos/\(repository)/releases/assets/\(id)")!
        let answer = try await send(ReleaseRequest(url: url, headers: Self.headers(token: token, accept: "application/octet-stream")))
        guard (200..<300).contains(answer.status) else { throw ReleaseCheckError.answered(status: answer.status, url: url) }
        let entries = (try? JSONDecoder().decode([Entry].self, from: answer.data)) ?? []
        manifests[id] = entries
        return entries
    }

    private static func headers(token: String, accept: String) -> [String: String] {
        ["Authorization": "Bearer \(token)", "Accept": accept, "X-GitHub-Api-Version": "2022-11-28"]
    }

    /// A release, as GitHub lists it: what the check reads of it.
    struct Release: Decodable, Sendable {
        var draft: Bool
        var prerelease: Bool
        var assets: [Asset]

        struct Asset: Decodable, Sendable {
            var id: Int
            var name: String
        }
    }

    /// A line of a release's `builds.json`: what the check reads of it.
    struct Entry: Decodable, Sendable {
        var file: String
        var bundleID: String
        var platform: String
        var version: String
        var buildNumber: String
        var variant: String
        /// False for a build copied unsigned; nil, signed.
        var signed: Bool?
        /// What an experiment's build is for; nil for an app's.
        var purpose: String?
    }
}

extension ReleaseChecker {
    /// GitHub over URLSession: redirects followed (an asset's, to where its
    /// file is kept), the token sent to no other host; nothing cached but
    /// what the checker keeps.
    public static let urlSession: Send = { request in try await ReleaseSession.shared.send(request) }
}

/// The URLSession the default transport sends through.
private final class ReleaseSession: @unchecked Sendable {
    static let shared = ReleaseSession()
    private let session: URLSession

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration, delegate: RedirectGuard(), delegateQueue: nil)
    }

    func send(_ request: ReleaseRequest) async throws -> ReleaseAnswer {
        var urlRequest = URLRequest(url: request.url)
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        return try await withCheckedThrowingContinuation { continuation in
            session.dataTask(with: urlRequest) { data, response, error in
                if let error { return continuation.resume(throwing: error) }
                guard let http = response as? HTTPURLResponse else { return continuation.resume(throwing: ReleaseCheckError.notHTTP) }
                var headers: [String: String] = [:]
                for (name, value) in http.allHeaderFields {
                    if let name = name as? String { headers[name] = "\(value)" }
                }
                continuation.resume(returning: ReleaseAnswer(status: http.statusCode, headers: headers, data: data ?? Data()))
            }.resume()
        }
    }
}

/// Follows a redirect without the token where it leads to another host: an
/// asset's file is kept elsewhere, at a signed URL that refuses a second
/// credential.
private final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        var next = request
        if next.url?.host != task.originalRequest?.url?.host { next.setValue(nil, forHTTPHeaderField: "Authorization") }
        completionHandler(next)
    }
}
