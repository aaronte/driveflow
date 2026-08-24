import XCTest
@testable import Driveflow

final class ShareAccessTests: XCTestCase {
    func testLicenseJSONParsesShareSession() {
        let json: [String: Any] = [
            "allowed": true,
            "shareEmail": "lic-test@driveflow-503421.iam.gserviceaccount.com",
            "accessToken": "ya29.test-token",
            "expiresIn": 1800,
        ]
        let session = ShareMintClient.session(fromLicenseJSON: json)
        XCTAssertEqual(session?.shareEmail, "lic-test@driveflow-503421.iam.gserviceaccount.com")
        XCTAssertEqual(session?.accessToken, "ya29.test-token")
        XCTAssertNotNil(session?.expiresAt)
    }

    func testLicenseJSONIgnoresMissingToken() {
        let json: [String: Any] = [
            "allowed": true,
            "shareEmail": "lic-test@driveflow-503421.iam.gserviceaccount.com",
        ]
        XCTAssertNil(ShareMintClient.session(fromLicenseJSON: json))
    }

    func testShareBrowseRootsHideMyDrive() {
        XCTAssertEqual(DriveRoot.shareBrowseRoots, [.sharedWithMe])
        XCTAssertFalse(DriveRoot.shareBrowseRoots.contains(.myDrive))
        XCTAssertFalse(DriveRoot.shareBrowseRoots.contains(.sharedDrives))
    }

    func testBoundFolderStoreRoundTrip() throws {
        let email = "share-access-test-\(UUID().uuidString)@example.com"
        defer { BoundFolderStore.clear(buyerEmail: email) }

        XCTAssertTrue(BoundFolderStore.load(buyerEmail: email).isEmpty)
        BoundFolderStore.save(["folder-a", "folder-b"], buyerEmail: email)
        XCTAssertEqual(BoundFolderStore.load(buyerEmail: email), ["folder-a", "folder-b"])
    }
}
