import Foundation

/// Expiry is read from the payload only. The mint server verifies the signature.
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
