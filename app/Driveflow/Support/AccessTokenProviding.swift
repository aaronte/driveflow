import Foundation

protocol AccessTokenProviding: AnyObject {
    func validAccessToken() async throws -> String
}
