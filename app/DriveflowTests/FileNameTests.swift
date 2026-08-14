import XCTest
@testable import Driveflow

final class FileNameTests: XCTestCase {
    func testSanitizeReplacesIllegalCharacters() {
        XCTAssertEqual(
            RcloneEngine.sanitizeFileName("a/b:c*.txt"),
            "a_b_c_.txt"
        )
    }

    func testSanitizeEmptyBecomesDownload() {
        XCTAssertEqual(RcloneEngine.sanitizeFileName("   "), "download")
    }

    func testDestinationAddsGoogleDocsExportExtension() {
        let name = RcloneEngine.destinationFileName(
            name: "Notes",
            isFolder: false,
            mimeType: "application/vnd.google-apps.document"
        )
        XCTAssertTrue(name.hasSuffix(".docx"), name)
    }

    func testDestinationSkipsFolders() {
        let name = RcloneEngine.destinationFileName(
            name: "Album",
            isFolder: true,
            mimeType: "application/vnd.google-apps.folder"
        )
        XCTAssertEqual(name, "Album")
    }
}
