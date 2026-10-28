import Foundation

/// Reads the `exp` claim from a Google OpenID Connect ID token.
///
/// The app does not verify the signature — Google minted the token, and the
/// share-mint server is what must verify it. Expiry here only decides when to
/// refresh before calling that server.
enum GoogleIDToken {
    static func expiresAt(_ jwt: String) -> Date? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2,
              let data = base64URLDecode(String(parts[1])),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        if let exp = json["exp"] as? Double {
            return Date(timeIntervalSince1970: exp)
        }
        if let exp = json["exp"] as? Int {
            return Date(timeIntervalSince1970: Double(exp))
        }
        return nil
    }

    /// True when the token has more than `leeway` seconds left.
    static func isFresh(_ jwt: String, now: Date = Date(), leeway: TimeInterval = 60) -> Bool {
        guard let exp = expiresAt(jwt) else { return false }
        return exp.timeIntervalSince(now) > leeway
    }

    private static func base64URLDecode(_ value: String) -> Data? {
        var payload = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = payload.count % 4
        if remainder > 0 {
            payload += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: payload)
    }
}
