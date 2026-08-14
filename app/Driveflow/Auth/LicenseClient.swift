import Foundation

enum LicenseClient {
    struct CheckResponse: Decodable {
        let allowed: Bool
    }

    /// Returns true when the email has a paid license.
    static func hasLicense(email: String) async throws -> Bool {
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
        let decoded = try JSONDecoder().decode(CheckResponse.self, from: data)
        return decoded.allowed
    }
}
