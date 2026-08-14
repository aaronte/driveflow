import XCTest
@testable import Driveflow

final class QueueDecodeTests: XCTestCase {
    func testDecodeModernQueuedItems() throws {
        let json = """
        [{
          "id": "11111111-1111-1111-1111-111111111111",
          "createdAt": 0,
          "updatedAt": 0,
          "items": [{"id":"file1","name":"Report.pdf","isFolder":false,"isSharedDriveRoot":false}],
          "destinationPath": "/tmp/out",
          "status": "paused",
          "rcloneJobIDs": ["9","10"],
          "bytesTransferred": 1,
          "totalBytes": 2
        }]
        """.data(using: .utf8)!

        let jobs = try JSONDecoder().decode([DownloadJob].self, from: json)
        XCTAssertEqual(jobs.count, 1)
        XCTAssertEqual(jobs[0].items.map(\.name), ["Report.pdf"])
        XCTAssertEqual(jobs[0].rcloneJobIDs, ["9", "10"])
    }

    func testDecodeLegacySingularRcloneJobID() throws {
        let json = """
        [{
          "id": "22222222-2222-2222-2222-222222222222",
          "createdAt": 0,
          "updatedAt": 0,
          "items": [{"id":"file1","name":"A","isFolder":false,"isSharedDriveRoot":false}],
          "destinationPath": "/tmp/out",
          "status": "paused",
          "rcloneJobID": "42",
          "bytesTransferred": 0,
          "totalBytes": 0
        }]
        """.data(using: .utf8)!

        let jobs = try JSONDecoder().decode([DownloadJob].self, from: json)
        XCTAssertEqual(jobs[0].rcloneJobIDs, ["42"])
    }

    func testDecodeLegacyParallelArrays() throws {
        let json = """
        [{
          "id": "33333333-3333-3333-3333-333333333333",
          "createdAt": 0,
          "updatedAt": 0,
          "itemIDs": ["a","b"],
          "itemNames": ["One","Two"],
          "itemIsFolders": [false, true],
          "destinationPath": "/tmp/out",
          "status": "queued",
          "bytesTransferred": 0,
          "totalBytes": 0
        }]
        """.data(using: .utf8)!

        let jobs = try JSONDecoder().decode([DownloadJob].self, from: json)
        XCTAssertEqual(jobs[0].items.count, 2)
        XCTAssertEqual(jobs[0].items[1].name, "Two")
        XCTAssertTrue(jobs[0].items[1].isFolder)
        XCTAssertEqual(jobs[0].rcloneJobIDs, [])
    }
}
