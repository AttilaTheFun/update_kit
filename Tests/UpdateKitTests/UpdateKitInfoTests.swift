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
        // Not a string, or a build variable no build filled in: not a group.
        XCTAssertNil(UpdateKitInfo.appGroup(in: [UpdateKitInfo.appGroupKey: 42]))
        XCTAssertNil(UpdateKitInfo.appGroup(in: [UpdateKitInfo.appGroupKey: "$(UPDATE_KIT_APP_GROUP)"]))
        XCTAssertNil(UpdateKitInfo.appGroup(in: [UpdateKitInfo.appGroupKey: "group.$(GROUP_SUFFIX)"]))
    }

    func testTheDistributorsBundleIDs() {
        XCTAssertEqual(UpdateKitInfo.applicationsBundleIDs(in: [UpdateKitInfo.applicationsBundleIDsKey: ["com.example.A", "", "com.example.B"]]),
                       ["com.example.A", "com.example.B"])
        XCTAssertEqual(UpdateKitInfo.applicationsBundleIDs(in: nil), [])
    }
}
