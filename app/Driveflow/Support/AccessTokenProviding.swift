import Foundation

/// Source of short-lived Bearer tokens for Google Drive API / rclone.
protocol AccessTokenProviding: AnyObject {
    func validAccessToken() async throws -> String
}
