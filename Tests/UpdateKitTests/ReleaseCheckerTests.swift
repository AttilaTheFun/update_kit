import Foundation
import Testing
import UpdateKit

/// An app's direct check of its own releases (ReleaseChecker), with GitHub
/// faked: the requests it sends, the releases its variant takes, and the
/// builds.json line it picks. Portable: these run on Linux.
@Suite
struct ReleaseCheckerTests {
    private let app = "com.example.App"

    private func installed(_ version: String = "1.0", build: String? = "1", variant: String? = nil) -> InstalledApp {
        InstalledApp(bundleID: app, version: version, build: build, variant: variant)
    }

    private func checker(_ github: FakeGitHub, token: String = "token-1") -> ReleaseChecker {
        ReleaseChecker(repository: "owner/app", token: { token }, send: { await github.answer($0) })
    }

    private func line(_ version: String, build: String = "1", bundleID: String? = nil, platform: String = "ios",
                      variant: String = "Production", extra: String = "") -> String {
        """
        {"file": "App-\(version)-\(platform).zip", "bundleID": "\(bundleID ?? app)", "app": "App", "platform": "\(platform)",
         "version": "\(version)", "buildNumber": "\(build)", "variant": "\(variant)", "commit": "", "size": 1\(extra)}
        """
    }

    @Test func theRequestsCarryTheTokenAndTheLastETag() async throws {
        let github = FakeGitHub(releases: [.init(asset: 7)], builds: [7: [line("1.1")]], etag: "\"abc\"")
        let checker = checker(github)

        let first = try await checker.check(app: installed(), platform: "ios")
        #expect(first == LatestBuild(bundleID: app, version: "1.1", build: "1", installURL: nil))
        let requests = await github.requests
        #expect(requests.map(\.url.absoluteString) == ["https://api.github.com/repos/owner/app/releases?per_page=10",
                                                       "https://api.github.com/repos/owner/app/releases/assets/7"])
        #expect(requests[0].headers == ["Authorization": "Bearer token-1", "Accept": "application/vnd.github+json",
                                        "X-GitHub-Api-Version": "2022-11-28"])
        #expect(requests[1].headers == ["Authorization": "Bearer token-1", "Accept": "application/octet-stream",
                                        "X-GitHub-Api-Version": "2022-11-28"])

        // Unchanged: a 304, the kept list read again, builds.json not fetched again.
        let second = try await checker.check(app: installed(), platform: "ios")
        #expect(second == first)
        let again = await github.requests
        #expect(again.count == 3)
        #expect(again[2].headers["If-None-Match"] == "\"abc\"")
        #expect(await github.notModified == 1)
    }

    @Test func aChangedListIsReadAgain() async throws {
        let github = FakeGitHub(releases: [.init(asset: 7)], builds: [7: [line("1.1")], 8: [line("1.2")]], etag: "\"one\"")
        let checker = checker(github)
        #expect(try await checker.check(app: installed(), platform: "ios")?.version == "1.1")
        await github.publish([.init(asset: 8), .init(asset: 7)], etag: "\"two\"")
        #expect(try await checker.check(app: installed(), platform: "ios")?.version == "1.2")
        // builds.json read once an asset id: 7, then 8.
        #expect(await github.assetsFetched == [7, 8])
        #expect(try await checker.check(app: installed(), platform: "ios")?.version == "1.2")
        #expect(await github.requests.last?.headers["If-None-Match"] == "\"two\"")
        #expect(await github.assetsFetched == [7, 8])
    }

    @Test func productionTakesOnlyPublishedReleases() async throws {
        let github = FakeGitHub(releases: [.init(asset: 1, draft: true), .init(asset: 2, prerelease: true), .init(asset: 3)],
                                builds: [1: [line("3.0")], 2: [line("2.0")], 3: [line("1.1")]])
        let found = try await checker(github).check(app: installed(variant: "Production"), platform: "ios")
        #expect(found?.version == "1.1")
        #expect(await github.assetsFetched == [3], "neither the draft's nor the pre-release's builds.json read")
        // An app that says no variant is Production's.
        #expect(try await checker(github).check(app: installed(), platform: "ios")?.version == "1.1")
    }

    @Test func betaTakesAPreReleaseButNotADraft() async throws {
        let github = FakeGitHub(releases: [.init(asset: 1, draft: true), .init(asset: 2, prerelease: true), .init(asset: 3)],
                                builds: [1: [line("3.0", variant: "Beta")], 2: [line("2.0", variant: "Beta")],
                                         3: [line("1.1", variant: "Beta")]])
        let found = try await checker(github).check(app: installed(variant: "Beta"), platform: "ios")
        #expect(found?.version == "2.0")
        #expect(await github.assetsFetched == [2, 3])
    }

    @Test func alphaAndAdHocTakeADraft() async throws {
        for variant in ["Alpha", "AdHoc"] {
            let github = FakeGitHub(releases: [.init(asset: 1, draft: true), .init(asset: 2, prerelease: true)],
                                    builds: [1: [line("3.0", variant: variant)], 2: [line("2.0", variant: variant)]])
            let found = try await checker(github).check(app: installed(variant: variant), platform: "ios")
            #expect(found?.version == "3.0", "\(variant)")
        }
    }

    @Test func theHighestOfTheAppsBuildsIsTaken() async throws {
        let github = FakeGitHub(releases: [.init(asset: 1), .init(asset: 2)], builds: [
            1: [line("1.10", build: "2"), line("1.10", build: "10"), line("1.9", build: "99")],
            2: [line("1.2", build: "1"), line("1.10", build: "3")],
        ])
        let found = try await checker(github).check(app: installed(), platform: "ios")
        #expect(found == LatestBuild(bundleID: app, version: "1.10", build: "10", installURL: nil))
    }

    @Test func nothingWhenNoneIsNewer() async throws {
        let github = FakeGitHub(releases: [.init(asset: 1)], builds: [1: [line("1.0", build: "1"), line("0.9")]])
        #expect(try await checker(github).check(app: installed("1.0", build: "1"), platform: "ios") == nil)
        #expect(try await checker(github).check(app: installed("1.1", build: "1"), platform: "ios") == nil)
    }

    @Test func otherAppsPlatformsVariantsAndUnsignedOrExperimentBuildsAreIgnored() async throws {
        let github = FakeGitHub(releases: [.init(asset: 1)], builds: [1: [
            line("9.0", bundleID: "com.example.Other"),
            line("9.1", platform: "macos"),
            line("9.2", variant: "Beta"),
            line("9.3", extra: ", \"signed\": false"),
            line("9.4", extra: ", \"purpose\": \"experiment\""),
            line("1.5", extra: ", \"signed\": true, \"unknown\": [1, 2]"),
        ]])
        let found = try await checker(github).check(app: installed(), platform: "ios")
        #expect(found?.version == "1.5")
        let mac = try await checker(github).check(app: installed(), platform: "macos")
        #expect(mac?.version == "9.1")
    }

    @Test func aReleaseWithoutBuildsJSONIsPassedOver() async throws {
        let github = FakeGitHub(releases: [.init(asset: 1, name: "App.zip"), .init(asset: 2)], builds: [1: [line("5.0")], 2: [line("1.1")]])
        #expect(try await checker(github).check(app: installed(), platform: "ios")?.version == "1.1")
        #expect(await github.assetsFetched == [2])
    }

    @Test func signedOutChecksNothing() async throws {
        let github = FakeGitHub(releases: [.init(asset: 1)], builds: [1: [line("1.1")]])
        #expect(try await checker(github, token: "").check(app: installed(), platform: "ios") == nil)
        #expect(await github.requests.isEmpty)
    }

    @Test func aRefusalIsAnError() async throws {
        let github = FakeGitHub(releases: [], builds: [:], status: 401)
        await #expect(throws: ReleaseCheckError.self) { try await checker(github).check(app: installed(), platform: "ios") }
    }
}

/// GitHub as a test sees it: a repository's releases, each with one asset
/// (builds.json unless named otherwise), and their builds.json by asset id.
actor FakeGitHub {
    struct Release: Sendable {
        var asset: Int
        var name = "builds.json"
        var draft = false
        var prerelease = false

        init(asset: Int, name: String = "builds.json", draft: Bool = false, prerelease: Bool = false) {
            self.asset = asset
            self.name = name
            self.draft = draft
            self.prerelease = prerelease
        }
    }

    private(set) var requests: [ReleaseRequest] = []
    private(set) var assetsFetched: [Int] = []
    private(set) var notModified = 0
    private var releases: [Release]
    private let builds: [Int: [String]]
    private var etag: String?
    private let status: Int

    init(releases: [Release], builds: [Int: [String]], etag: String? = nil, status: Int = 200) {
        self.releases = releases
        self.builds = builds
        self.etag = etag
        self.status = status
    }

    func publish(_ releases: [Release], etag: String) {
        self.releases = releases
        self.etag = etag
    }

    func answer(_ request: ReleaseRequest) -> ReleaseAnswer {
        requests.append(request)
        guard status == 200 else { return ReleaseAnswer(status: status) }
        let path = request.url.path
        if path.hasSuffix("/releases") {
            if let etag, request.headers["If-None-Match"] == etag {
                notModified += 1
                return ReleaseAnswer(status: 304, headers: ["ETag": etag])
            }
            let list = releases.map { release in
                """
                {"id": \(release.asset * 100), "draft": \(release.draft), "prerelease": \(release.prerelease), "tag_name": "v\(release.asset)",
                 "assets": [{"id": \(release.asset), "name": "\(release.name)", "size": 1}]}
                """
            }
            return ReleaseAnswer(status: 200, headers: etag.map { ["etag": $0] } ?? [:], data: Data("[\(list.joined(separator: ","))]".utf8))
        }
        guard let id = Int(request.url.lastPathComponent), let lines = builds[id] else { return ReleaseAnswer(status: 404) }
        assetsFetched.append(id)
        return ReleaseAnswer(status: 200, data: Data("[\(lines.joined(separator: ","))]".utf8))
    }
}
