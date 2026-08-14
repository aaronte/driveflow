import Foundation

enum AppConfig {
    static let appName = "Driveflow"
    static let bundleID = "com.aaronte.driveflow"

    /// Google OAuth Desktop client credentials.
    ///
    /// Resolution order (first non-empty wins):
    /// 1. `DRIVEFLOW_GOOGLE_CLIENT_ID` / `DRIVEFLOW_GOOGLE_CLIENT_SECRET` env vars
    /// 2. gitignored `oauth-client.json` (bundled Resources, Application Support, or source tree)
    ///
    /// Desktop clients still require `client_secret` on the token endpoint even when using PKCE.
    /// Never commit real credentials — see `Resources/oauth-client.example.json`.
    static let googleClientID = credential(
        env: "DRIVEFLOW_GOOGLE_CLIENT_ID",
        fileKey: "client_id",
        placeholder: "REPLACE_WITH_DESKTOP_CLIENT_ID"
    )
    static let googleClientSecret = credential(
        env: "DRIVEFLOW_GOOGLE_CLIENT_SECRET",
        fileKey: "client_secret",
        placeholder: "REPLACE_WITH_DESKTOP_CLIENT_SECRET"
    )

    private static func credential(env: String, fileKey: String, placeholder: String) -> String {
        if let value = ProcessInfo.processInfo.environment[env]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return value
        }
        if let value = localOAuthCredentials[fileKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return value
        }
        return placeholder
    }

    /// Local OAuth JSON candidates (all gitignored / machine-local).
    private static let localOAuthCredentials: [String: String] = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Driveflow/oauth-client.json")
        let candidates: [URL?] = [
            Bundle.main.url(forResource: "oauth-client", withExtension: "json"),
            support,
            URL(fileURLWithPath: #file)
                .deletingLastPathComponent()
                .appendingPathComponent("Resources/oauth-client.json"),
        ]
        for url in candidates {
            guard let url,
                  let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            // Supports raw `{client_id, client_secret}` or Google's downloaded `installed` shape.
            let root = (json["installed"] as? [String: Any]) ?? (json["web"] as? [String: Any]) ?? json
            if let id = root["client_id"] as? String, let secret = root["client_secret"] as? String {
                return ["client_id": id, "client_secret": secret]
            }
        }
        return [:]
    }()

    static let googleAuthEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static let googleTokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    static let googleRevokeEndpoint = URL(string: "https://oauth2.googleapis.com/revoke")!

    /// Drive access plus email (needed for license checks after sign-in).
    static let oauthScopes = "openid email https://www.googleapis.com/auth/drive.readonly"
    static let driveScope = oauthScopes
    static let driveAPIBase = URL(string: "https://www.googleapis.com/drive/v3")!

    static let rcloneRCUser = "driveflow"

    /// Marketing / buy URL shown when a license check fails.
    static let buyURL = URL(string: "https://usedriveflow.app/#pricing")!

    /// Public license-check endpoint (Next `/api/license/check` or Convex HTTP).
    /// Override with `DRIVEFLOW_LICENSE_CHECK_URL` for local/staging.
    static var licenseCheckURL: URL {
        if let raw = ProcessInfo.processInfo.environment["DRIVEFLOW_LICENSE_CHECK_URL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty,
           let url = URL(string: raw) {
            return url
        }
        return URL(string: "https://usedriveflow.app/api/license/check")!
    }

    /// Paid notarized builds set `DRIVEFLOW_PAID_BUILD` at compile time (see release script).
    /// Local/OSS builds stay ungated unless `DRIVEFLOW_REQUIRES_LICENSE=1` is set at runtime.
    static var requiresPaidLicense: Bool {
        #if DRIVEFLOW_PAID_BUILD
        return true
        #else
        let flag = ProcessInfo.processInfo.environment["DRIVEFLOW_REQUIRES_LICENSE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return flag == "1" || flag == "true" || flag == "yes"
        #endif
    }

    /// Google Desktop clients require a loopback redirect; custom schemes are
    /// rejected with `invalid_request`.
    static func redirectURI(port: UInt16) -> String { "http://127.0.0.1:\(port)" }
}
