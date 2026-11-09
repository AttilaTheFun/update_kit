import XCTest
@testable import UpdateKit

/// The app group and the distributor's bundle ids come from the app's
/// Info.plist, which the distributor's CI stamps; without them, nothing.
final class UpdateKitInfoTests: XCTestCase {
    func testTheAppGroupIsTheInfoPlists() {
        XCTAssertEqual(UpdateKitInfo.appGroup(in: [UpdateKitInfo.appGroupKey: "group.com.example.Distributor"]), "group.com.example.Distributor")
        XCTAssertEqual(UpdateKitInfo.appGroup(in: [UpdateKitInfo.appGroupKey: "  group.com.example.Distributor\n"]), "group.com.example.Distributor")
    }

    func testNoAppGroupIsNil() {
        XCTAssertNil(UpdateKitInfo.appGroup(in: nil))
        XCTAssertNil(UpdateKitInfo.appGroup(in: [:]))
        XCTAssertNil(UpdateKitInfo.appGroup(in: [UpdateKitInfo.appGroupKey: ""]))
        // A build variable the CI never filled in is not a group either.
        XCTAssertNil(UpdateKitInfo.appGroup(in: [UpdateKitInfo.appGroupKey: 42]))
    }

    func testTheDistributorsBundleIDs() {
        XCTAssertEqual(UpdateKitInfo.applicationsBundleIDs(in: [UpdateKitInfo.applicationsBundleIDsKey: ["com.example.A", "", "com.example.B"]]),
                       ["com.example.A", "com.example.B"])
        XCTAssertEqual(UpdateKitInfo.applicationsBundleIDs(in: nil), [])
    }

    @MainActor
    func testTheStatusSaysWhatTheCheckFound() {
        let status = UpdateStatus()
        XCTAssertNil(status.available)
        XCTAssertFalse(status.checks)
        let update = AvailableUpdate(bundleID: "com.example.App", version: "1.2", build: "3", installURL: nil,
                                     installedVersion: "1.1", installedBuild: "1")
        status.found(.available(update))
        XCTAssertEqual(status.available, update)
        XCTAssertTrue(status.checks)
        status.found(.upToDate)
        XCTAssertNil(status.available)
    }
}
