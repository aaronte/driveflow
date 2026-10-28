import Foundation

protocol AccessTokenProviding: AnyObject {
    func validAccessToken() async throws -> String
    /// Mint a replacement after Drive rejected the current service-account token.
    func refreshAfterUnauthorized() async throws
}
