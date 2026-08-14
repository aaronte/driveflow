import Foundation
import CryptoKit

enum PKCE {
    struct Pair {
        let verifier: String
        let challenge: String
    }

    static func generate() -> Pair {
        let verifier = randomURLSafe(length: 64)
        let challengeData = Data(SHA256.hash(data: Data(verifier.utf8)))
        let challenge = base64URL(challengeData)
        return Pair(verifier: verifier, challenge: challenge)
    }

    private static func randomURLSafe(length: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return String(base64URL(Data(bytes)).prefix(length))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
