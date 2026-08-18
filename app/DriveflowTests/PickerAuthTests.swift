import XCTest
@testable import Driveflow

final class PickerAuthTests: XCTestCase {
    func testParsePickedFileIDsSplitsCommaList() {
        XCTAssertEqual(
            AuthSession.parsePickedFileIDs("abc,def,ghi"),
            ["abc", "def", "ghi"]
        )
    }

    func testParsePickedFileIDsTrimsWhitespace() {
        XCTAssertEqual(
            AuthSession.parsePickedFileIDs(" a , b "),
            ["a", "b"]
        )
    }

    func testParsePickedFileIDsEmpty() {
        XCTAssertEqual(AuthSession.parsePickedFileIDs(nil), [])
        XCTAssertEqual(AuthSession.parsePickedFileIDs(""), [])
        XCTAssertEqual(AuthSession.parsePickedFileIDs("  , , "), [])
    }

    func testOAuthScopeIsDriveFileOnly() {
        XCTAssertEqual(
            AppConfig.oauthScopes,
            "https://www.googleapis.com/auth/drive.file"
        )
        XCTAssertFalse(AppConfig.oauthScopes.contains("drive.readonly"))
        XCTAssertFalse(AppConfig.oauthScopes.contains("openid"))
        XCTAssertEqual(AppConfig.driveScope, "drive.file")
    }
}
