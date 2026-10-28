import Foundation

enum LicenseClient {
    struct CheckResult: Sendable {
        let allowed: Bool
        /// Present when the license server also mints a share/Drive session.
        let shareSession: ShareMintClient.Session?
    }

    static func check(email: String) async throws -> CheckResult {
        let url = AppConfig.licenseCheckURL
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20
        let payload = ["email": email]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AppError.network("No response from license server.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AppError.network("License check failed (HTTP \(http.statusCode)).")
        }
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let allowed = (json["allowed"] as? Bool) ?? false
        let share = ShareMintClient.session(fromLicenseJSON: json)
        return CheckResult(allowed: allowed, shareSession: share)
    }

    static func hasLicense(email: String) async throws -> Bool {
        try await check(email: email).allowed
    }
}
