import Foundation

enum ShareMintClient {
    struct Session: Equatable, Sendable {
        let shareEmail: String
        let accessToken: String
        let expiresAt: Date
    }

    enum MintServerReply: Equatable {
        case ready(Session)
        case reauthenticate
        case unpaid
        case backoff(TimeInterval)
        case rateLimited
        case mintFailed
        case other(statusCode: Int)
    }

    struct MintAPIResponse: Decodable {
        let shareEmail: String
        let accessToken: String
        let expiresIn: Double?
        let expiresAt: Double?
    }

    static func mint(googleIDToken: String) async throws -> Session {
        let token = googleIDToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw AppError.authFailed(
                "Sign in again so Driveflow can verify your Google account before opening Drive."
            )
        }
        return try await mintFromAPI(idToken: token)
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

    static func interpretReply(
        statusCode: Int,
        data: Data,
        retryAttempt: Int,
        retryAfterHeader: String?,
        now: Date = Date()
    ) throws -> MintServerReply {
        switch httpOutcome(for: statusCode) {
        case .success:
            return .ready(try session(fromMintData: data, now: now))
        case .reauthenticate:
            return .reauthenticate
        case .unpaid:
            return .unpaid
        case .retry:
            if retryAttempt < maxRateLimitRetries {
                return .backoff(
                    retryDelaySeconds(
                        attempt: retryAttempt,
                        retryAfterHeader: retryAfterHeader,
                        now: now
                    )
                )
            }
            return .rateLimited
        case .mintFailed:
            return .mintFailed
        case .other:
            return .other(statusCode: statusCode)
        }
    }

    static func failure(for reply: MintServerReply) -> AppError {
        switch reply {
        case .ready, .backoff:
            preconditionFailure("A successful mint reply is not a failure")
        case .reauthenticate:
            return .shareMintUnauthorized
        case .unpaid:
            return .licenseRequired(email: nil)
        case .rateLimited:
            return .shareMintRateLimited
        case .mintFailed:
            return .shareMintFailed
        case .other(let statusCode):
            return .network("Share mint failed (HTTP \(statusCode)).")
        }
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
        let url = AppConfig.shareMintURL
        var rateLimitRetries = 0
        while true {
            let request = mintRequest(url: url, googleIDToken: idToken)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw AppError.network("No response from share mint server.")
            }
            let reply = try interpretReply(
                statusCode: http.statusCode,
                data: data,
                retryAttempt: rateLimitRetries,
                retryAfterHeader: http.value(forHTTPHeaderField: "Retry-After")
            )
            switch reply {
            case .ready(let session):
                return session
            case .backoff(let delay):
                rateLimitRetries += 1
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            case .reauthenticate, .unpaid, .rateLimited, .mintFailed:
                throw failure(for: reply)
            case .other(_):
                throw failure(for: reply)
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
}
