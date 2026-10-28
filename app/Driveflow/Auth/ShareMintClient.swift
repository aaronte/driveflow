import Foundation
import Security

enum ShareMintClient {
    struct Session: Sendable {
        let shareEmail: String
        let accessToken: String
        let expiresAt: Date
    }

    struct MintAPIResponse: Decodable {
        let shareEmail: String
        let accessToken: String
        let expiresIn: Double?
        let expiresAt: Double?
    }

    static func mint(googleIDToken: String?) async throws -> Session {
        if AppConfig.shareMintURL != nil {
            let token = googleIDToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !token.isEmpty else {
                throw AppError.authFailed(
                    "Sign in again so Driveflow can verify your Google account before opening Drive."
                )
            }
            return try await mintFromAPI(idToken: token)
        }
        // No mint URL: dev-only local key or env token. API failures never reach this.
        if let session = try await mintFromLocalServiceAccount() {
            return session
        }
        if let session = sessionFromEnvToken() {
            return session
        }
        throw AppError.shareAccessNotConfigured
    }

    /// How the mint server told us to proceed. `500` is mint failure; other 5xx stay `.other`.
    enum HTTPOutcome: Equatable {
        case success
        case reauthenticate
        case unpaid
        case retry
        case mintFailed
        case other
    }

    static let maxRateLimitRetries = 3

    static func httpOutcome(for statusCode: Int) -> HTTPOutcome {
        switch statusCode {
        case 200..<300:
            return .success
        case 401:
            return .reauthenticate
        case 402:
            return .unpaid
        case 429:
            return .retry
        case 500:
            return .mintFailed
        default:
            return .other
        }
    }

    static func retryDelaySeconds(attempt: Int, retryAfterHeader: String?, now: Date = Date()) -> TimeInterval {
        if let header = retryAfterHeader?.trimmingCharacters(in: .whitespacesAndNewlines),
           !header.isEmpty {
            if let seconds = TimeInterval(header), seconds >= 0 {
                return min(seconds, 30)
            }
            if let date = retryAfterDate(header), date > now {
                return min(date.timeIntervalSince(now), 30)
            }
        }
        let exponential = pow(2.0, Double(max(0, attempt)))
        return min(exponential, 30)
    }

    static func mintRequest(url: URL, googleIDToken: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(googleIDToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20
        let payload = ["idToken": googleIDToken]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        return request
    }

    static func session(fromMintData data: Data, now: Date = Date()) throws -> Session {
        let decoded: MintAPIResponse
        do {
            decoded = try JSONDecoder().decode(MintAPIResponse.self, from: data)
        } catch {
            throw AppError.network("Share mint response was missing shareEmail/accessToken.")
        }
        let shareEmail = decoded.shareEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        let accessToken = decoded.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !shareEmail.isEmpty, !accessToken.isEmpty else {
            throw AppError.network("Share mint response was missing shareEmail/accessToken.")
        }
        let expiresAt: Date
        if let expiresAtEpoch = decoded.expiresAt {
            expiresAt = Date(timeIntervalSince1970: expiresAtEpoch)
        } else if let expiresIn = decoded.expiresIn {
            expiresAt = now.addingTimeInterval(expiresIn)
        } else {
            throw AppError.network("Share mint response was missing expiresAt.")
        }
        return Session(shareEmail: shareEmail, accessToken: accessToken, expiresAt: expiresAt)
    }

    static func session(fromLicenseJSON json: [String: Any]) -> Session? {
        guard let shareEmail = (json["shareEmail"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !shareEmail.isEmpty,
              let accessToken = (json["accessToken"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !accessToken.isEmpty
        else {
            return nil
        }
        let expiresAt: Date
        if let expiresAtEpoch = json["expiresAt"] as? Double {
            expiresAt = Date(timeIntervalSince1970: expiresAtEpoch)
        } else {
            let expiresIn = (json["expiresIn"] as? Double) ?? 3600
            expiresAt = Date().addingTimeInterval(expiresIn)
        }
        return Session(shareEmail: shareEmail, accessToken: accessToken, expiresAt: expiresAt)
    }

    private static func mintFromAPI(idToken: String) async throws -> Session {
        guard let url = AppConfig.shareMintURL else {
            throw AppError.shareAccessNotConfigured
        }

        var rateLimitRetries = 0
        while true {
            let request = mintRequest(url: url, googleIDToken: idToken)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw AppError.network("No response from share mint server.")
            }
            switch httpOutcome(for: http.statusCode) {
            case .success:
                return try session(fromMintData: data)
            case .retry where rateLimitRetries < maxRateLimitRetries:
                let delay = retryDelaySeconds(
                    attempt: rateLimitRetries,
                    retryAfterHeader: http.value(forHTTPHeaderField: "Retry-After")
                )
                rateLimitRetries += 1
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            case .retry:
                throw AppError.shareMintRateLimited
            case .reauthenticate:
                throw AppError.shareMintUnauthorized
            case .unpaid:
                throw AppError.licenseRequired(email: nil)
            case .mintFailed:
                throw AppError.shareMintFailed
            case .other:
                let body = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
                throw AppError.network("Share mint failed (HTTP \(http.statusCode)). \(body)")
            }
        }
    }

    private static func retryAfterDate(_ header: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: header)
    }

    private static func sessionFromEnvToken() -> Session? {
        let email = ProcessInfo.processInfo.environment["DRIVEFLOW_SHARE_EMAIL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let token = ProcessInfo.processInfo.environment["DRIVEFLOW_SHARE_ACCESS_TOKEN"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let email, !email.isEmpty, let token, !token.isEmpty else { return nil }
        let expiresIn = Double(
            ProcessInfo.processInfo.environment["DRIVEFLOW_SHARE_TOKEN_EXPIRES_IN"] ?? "3500"
        ) ?? 3500
        return Session(
            shareEmail: email,
            accessToken: token,
            expiresAt: Date().addingTimeInterval(expiresIn)
        )
    }

    private static func mintFromLocalServiceAccount() async throws -> Session? {
        guard let key = loadLocalServiceAccountKey() else { return nil }
        return try await exchangeJWT(for: key)
    }

    private static func loadLocalServiceAccountKey() -> ServiceAccountKeyFile? {
        let envPath = ProcessInfo.processInfo.environment["DRIVEFLOW_SA_KEY_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Driveflow/service-account.json")
        let candidates: [URL?] = [
            envPath.map { URL(fileURLWithPath: $0) },
            support,
            URL(fileURLWithPath: #file)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Resources/service-account.json"),
        ]
        for url in candidates {
            guard let url,
                  let data = try? Data(contentsOf: url),
                  let key = try? JSONDecoder().decode(ServiceAccountKeyFile.self, from: data)
            else { continue }
            return key
        }
        return nil
    }

    private static func exchangeJWT(for key: ServiceAccountKeyFile) async throws -> Session {
        let now = Date()
        let assertion = try makeJWTAssertion(key: key, issuedAt: now)
        var request = URLRequest(url: URL(string: key.tokenURI) ?? AppConfig.googleTokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let encodedAssertion =
            assertion.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? assertion
        let body =
            "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=\(encodedAssertion)"
        request.httpBody = Data(body.utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AppError.network("No response from Google token endpoint.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw AppError.authFailed("Service account token exchange failed. \(message)")
        }
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        guard let access = json["access_token"] as? String else {
            throw AppError.authFailed("Service account token response missing access_token.")
        }
        let expiresIn = (json["expires_in"] as? Double) ?? 3600
        return Session(
            shareEmail: key.clientEmail,
            accessToken: access,
            expiresAt: now.addingTimeInterval(expiresIn)
        )
    }

    private static func makeJWTAssertion(key: ServiceAccountKeyFile, issuedAt: Date) throws -> String {
        let header: [String: Any] = [
            "alg": "RS256",
            "typ": "JWT",
            "kid": key.privateKeyID,
        ]
        let iat = Int(issuedAt.timeIntervalSince1970)
        let claims: [String: Any] = [
            "iss": key.clientEmail,
            "sub": key.clientEmail,
            "scope": AppConfig.driveReadonlyScope,
            "aud": key.tokenURI,
            "iat": iat,
            "exp": iat + 3600,
        ]
        let headerPart = try base64URLJSON(header)
        let claimsPart = try base64URLJSON(claims)
        let signingInput = "\(headerPart).\(claimsPart)"
        let signature = try signRS256(signingInput, pemPrivateKey: key.privateKey)
        return "\(signingInput).\(signature)"
    }

    private static func base64URLJSON(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return base64URL(data)
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func signRS256(_ message: String, pemPrivateKey: String) throws -> String {
        let key = try secKey(fromPKCS8PEM: pemPrivateKey)
        guard let messageData = message.data(using: .utf8) else {
            throw AppError.authFailed("Couldn’t encode JWT signing input.")
        }
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            key,
            .rsaSignatureMessagePKCS1v15SHA256,
            messageData as CFData,
            &error
        ) as Data?
        else {
            let detail = error?.takeRetainedValue().localizedDescription ?? "signature failed"
            throw AppError.authFailed("Couldn’t sign service-account JWT. \(detail)")
        }
        return base64URL(signature)
    }

    private static func secKey(fromPKCS8PEM pem: String) throws -> SecKey {
        let stripped = pem
            .replacingOccurrences(of: "-----BEGIN PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----END PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let der = Data(base64Encoded: stripped) else {
            throw AppError.authFailed("Invalid service-account private key PEM.")
        }
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, &error) else {
            let detail = error?.takeRetainedValue().localizedDescription ?? "SecKeyCreateWithData failed"
            throw AppError.authFailed("Couldn’t load service-account private key. \(detail)")
        }
        return key
    }
}

/// Google Cloud service-account key file (local/dev only).
private struct ServiceAccountKeyFile: Decodable {
    let privateKeyID: String
    let privateKey: String
    let clientEmail: String
    let tokenURI: String

    enum CodingKeys: String, CodingKey {
        case privateKeyID = "private_key_id"
        case privateKey = "private_key"
        case clientEmail = "client_email"
        case tokenURI = "token_uri"
    }
}
