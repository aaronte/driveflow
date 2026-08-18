import Foundation
import AppKit
import CryptoKit

@MainActor
final class AuthSession: NSObject, ObservableObject {
    @Published private(set) var isSignedIn = false
    @Published private(set) var userEmail: String?
    @Published private(set) var isBusy = false
    /// File IDs returned by the most recent Google desktop Picker redirect.
    @Published private(set) var lastPickedFileIDs: [String] = []
    @Published var lastError: AppError?

    private let accessAccount = "google.access"
    private let refreshAccount = "google.refresh"
    private let emailAccount = "google.email"
    private let expiryAccount = "google.expiry"
    private let signInTimeoutSeconds: TimeInterval = 180

    private static let formAllowedCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// Active loopback server for the in-flight browser sign-in (cancelled via `cancelSignIn()`).
    private var activeAuthServer: LoopbackAuthServer?

    override init() {
        super.init()
        Task { await restoreSession() }
    }

    var accessToken: String? {
        try? CredentialStore.get(account: accessAccount)
    }

    func restoreSession() async {
        let scheme = try? CredentialStore.get(account: AppConfig.authSchemeAccount)
        guard scheme == AppConfig.authSchemePickerV1 else {
            // Drop legacy `drive.readonly` (or unknown) sessions — picker requires re-consent.
            clearTokens()
            isSignedIn = false
            return
        }
        guard let refresh = try? CredentialStore.get(account: refreshAccount), !refresh.isEmpty else {
            isSignedIn = false
            return
        }
        do {
            try await refreshAccessToken(using: refresh)
            userEmail = try CredentialStore.get(account: emailAccount)
            try await enforcePaidLicenseIfNeeded()
            isSignedIn = true
        } catch let error as AppError {
            if case .authRevoked = error {
                clearTokens()
            } else if case .licenseRequired = error {
                clearTokens()
                lastError = error
            } else if AppConfig.requiresPaidLicense {
                // Fail closed: stay signed out until license check succeeds.
                lastError = error
            }
            isSignedIn = false
        } catch {
            // Offline / transient Google refresh failures: keep tokens so the user can retry.
            isSignedIn = false
        }
    }

    func signIn() async {
        lastError = nil
        guard !AppConfig.googleClientID.hasPrefix("REPLACE_WITH"),
              !AppConfig.googleClientSecret.hasPrefix("REPLACE_WITH") else {
            lastError = .notConfigured
            return
        }

        isBusy = true
        defer { isBusy = false }

        do {
            let pickedIDs = try await runDesktopPickerAuth()
            lastPickedFileIDs = pickedIDs
            try await fetchUserEmailFromDriveAbout()
            try await enforcePaidLicenseIfNeeded()
            try CredentialStore.set(AppConfig.authSchemePickerV1, account: AppConfig.authSchemeAccount)
            isSignedIn = true
        } catch let error as AppError {
            // Cancel / timeout shouldn't look like a hard failure unless user cares.
            if case .authCancelled = error {
                lastError = nil
            } else if case .licenseRequired = error {
                clearTokens()
                isSignedIn = false
                lastError = error
            } else {
                lastError = error
            }
        } catch is CancellationError {
            lastError = nil
        } catch {
            lastError = .authFailed(error.localizedDescription)
        }
    }

    /// Opens Google’s desktop Picker again so the user can grant more files this session.
    func pickAdditionalFiles() async throws -> [String] {
        lastError = nil
        guard isSignedIn else {
            throw AppError.authFailed("Sign in before choosing files from Google Drive.")
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let pickedIDs = try await runDesktopPickerAuth()
            lastPickedFileIDs = pickedIDs
            return pickedIDs
        } catch let error as AppError {
            if case .authCancelled = error {
                lastError = nil
            } else {
                lastError = error
            }
            throw error
        } catch {
            let wrapped = AppError.authFailed(error.localizedDescription)
            lastError = wrapped
            throw wrapped
        }
    }

    /// Aborts an in-flight browser sign-in and returns the UI to idle.
    func cancelSignIn() {
        activeAuthServer?.stop()
    }

    /// Official desktop Picker OAuth: `drive.file` only + `trigger_onepick`.
    private func runDesktopPickerAuth() async throws -> [String] {
        let server = LoopbackAuthServer()
        activeAuthServer = server
        defer {
            server.stop()
            activeAuthServer = nil
        }

        let port = try await server.start()
        let redirectURI = AppConfig.redirectURI(port: port)
        let pkce = PKCE.generate()
        let state = UUID().uuidString

        var components = URLComponents(url: AppConfig.googleAuthEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: AppConfig.googleClientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            // Desktop Picker forbids combining drive.file with any other scope.
            URLQueryItem(name: "scope", value: AppConfig.oauthScopes),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "trigger_onepick", value: "true"),
            URLQueryItem(name: "allow_multiple", value: "true"),
            URLQueryItem(name: "allow_folder_selection", value: "true"),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]

        guard let authURL = components.url else {
            throw AppError.authFailed("Invalid authorization URL.")
        }

        guard NSWorkspace.shared.open(authURL) else {
            throw AppError.authFailed("Couldn’t open your browser for Google Drive.")
        }

        let params = try await waitForSignInCallback(on: server)

        if let err = params["error"] {
            if err == "access_denied" {
                throw AppError.authCancelled
            }
            throw AppError.authFailed(err)
        }
        guard params["state"] == state else {
            throw AppError.authFailed("Sign-in response didn’t match this request. Try signing in again.")
        }
        guard let code = params["code"] else {
            throw AppError.authFailed("Missing authorization code.")
        }

        try await exchangeCode(code, verifier: pkce.verifier, redirectURI: redirectURI)
        return Self.parsePickedFileIDs(params["picked_file_ids"])
    }

    private func waitForSignInCallback(on server: LoopbackAuthServer) async throws -> [String: String] {
        let timeoutNanoseconds = UInt64(signInTimeoutSeconds * 1_000_000_000)
        return try await withThrowingTaskGroup(of: [String: String].self) { group in
            group.addTask {
                try await server.waitForCallback()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                throw AppError.authFailed("Sign-in timed out. Try again when you’re ready.")
            }
            defer { group.cancelAll() }
            guard let params = try await group.next() else {
                throw AppError.authCancelled
            }
            return params
        }
    }

    func signOut() {
        let tokenToRevoke =
            (try? CredentialStore.get(account: refreshAccount))
            ?? (try? CredentialStore.get(account: accessAccount))
        clearTokens()
        isSignedIn = false
        userEmail = nil
        lastPickedFileIDs = []
        if let tokenToRevoke, !tokenToRevoke.isEmpty {
            Task { await Self.revokeGoogleGrant(token: tokenToRevoke) }
        }
    }

    func validAccessToken() async throws -> String {
        if let expiryString = try CredentialStore.get(account: expiryAccount),
           let expiry = TimeInterval(expiryString),
           Date().timeIntervalSince1970 < expiry - 60,
           let token = try CredentialStore.get(account: accessAccount) {
            return token
        }
        guard let refresh = try CredentialStore.get(account: refreshAccount) else {
            throw AppError.tokenExpired
        }
        try await refreshAccessToken(using: refresh)
        guard let token = try CredentialStore.get(account: accessAccount) else {
            throw AppError.tokenExpired
        }
        return token
    }

    /// rclone-compatible OAuth token JSON for configuring the Drive remote.
    func rcloneTokenJSON() async throws -> String {
        let access = try await validAccessToken()
        let refresh = (try? CredentialStore.get(account: refreshAccount)) ?? ""
        let expiryDate: Date
        if let expiryString = try? CredentialStore.get(account: expiryAccount),
           let expiry = TimeInterval(expiryString) {
            expiryDate = Date(timeIntervalSince1970: expiry)
        } else {
            expiryDate = Date().addingTimeInterval(3600)
        }
        let payload: [String: Any] = [
            "access_token": access,
            "token_type": "Bearer",
            "refresh_token": refresh,
            "expiry": ISO8601DateFormatter().string(from: expiryDate),
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func exchangeCode(_ code: String, verifier: String, redirectURI: String) async throws {
        var request = URLRequest(url: AppConfig.googleTokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = [
            "client_id": AppConfig.googleClientID,
            "client_secret": AppConfig.googleClientSecret,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirectURI,
        ]
        request.httpBody = formEncode(body).data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        try persistTokenResponse(data: data, response: response)
    }

    private func refreshAccessToken(using refresh: String) async throws {
        var request = URLRequest(url: AppConfig.googleTokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = [
            "client_id": AppConfig.googleClientID,
            "client_secret": AppConfig.googleClientSecret,
            "refresh_token": refresh,
            "grant_type": "refresh_token",
        ]
        request.httpBody = formEncode(body).data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        try persistTokenResponse(data: data, response: response, fallbackRefresh: refresh)
    }

    private func persistTokenResponse(data: Data, response: URLResponse, fallbackRefresh: String? = nil) throws {
        guard let http = response as? HTTPURLResponse else {
            throw AppError.network("No response from Google.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            if (400..<500).contains(http.statusCode),
               message.contains("invalid_grant") || message.contains("invalid_client") {
                throw AppError.authRevoked(message)
            }
            throw AppError.authFailed(message)
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard let access = json["access_token"] as? String else {
            throw AppError.authFailed("Missing access token.")
        }
        try CredentialStore.set(access, account: accessAccount)
        if let refresh = json["refresh_token"] as? String {
            try CredentialStore.set(refresh, account: refreshAccount)
        } else if let fallbackRefresh {
            try CredentialStore.set(fallbackRefresh, account: refreshAccount)
        }
        let expiresIn = (json["expires_in"] as? Double) ?? 3600
        let expiry = Date().timeIntervalSince1970 + expiresIn
        try CredentialStore.set(String(expiry), account: expiryAccount)
    }

    /// Email via Drive `about.get` — allowed with `drive.file`, no openid/email scopes.
    private func fetchUserEmailFromDriveAbout() async throws {
        let token = try await validAccessToken()
        var components = URLComponents(
            url: AppConfig.driveAPIBase.appendingPathComponent("about"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "fields", value: "user(emailAddress)"),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8) ?? "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)"
            throw AppError.authFailed("Couldn’t read your Google account email. \(detail)")
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let user = json["user"] as? [String: Any] ?? [:]
        guard let email = (user["emailAddress"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !email.isEmpty
        else {
            throw AppError.authFailed("Google didn’t return an email for this account. Try another Google account.")
        }
        try CredentialStore.set(email, account: emailAccount)
        userEmail = email
    }

    /// Paid builds: require a matching purchase email before treating the session as signed in.
    private func enforcePaidLicenseIfNeeded() async throws {
        guard AppConfig.requiresPaidLicense else { return }
        guard let email = userEmail?.trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty else {
            throw AppError.licenseRequired(email: nil)
        }
        do {
            let allowed = try await LicenseClient.hasLicense(email: email)
            if !allowed {
                throw AppError.licenseRequired(email: email)
            }
        } catch let error as AppError {
            throw error
        } catch {
            // Fail closed for paid builds — don't allow offline bypass of the gate.
            throw AppError.network("Couldn’t verify your Driveflow license. \(error.localizedDescription)")
        }
    }

    private func clearTokens() {
        CredentialStore.delete(account: accessAccount)
        CredentialStore.delete(account: refreshAccount)
        CredentialStore.delete(account: emailAccount)
        CredentialStore.delete(account: expiryAccount)
        CredentialStore.delete(account: AppConfig.authSchemeAccount)
    }

    /// Best-effort remote revoke; local sign-out must not fail if offline.
    private static func revokeGoogleGrant(token: String) async {
        var request = URLRequest(url: AppConfig.googleRevokeEndpoint)
        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded",
            forHTTPHeaderField: "Content-Type"
        )
        let encoded = token.addingPercentEncoding(
            withAllowedCharacters: formAllowedCharacters
        ) ?? token
        request.httpBody = Data("token=\(encoded)".utf8)
        _ = try? await URLSession.shared.data(for: request)
    }

    static func parsePickedFileIDs(_ raw: String?) -> [String] {
        guard let raw, !raw.isEmpty else { return [] }
        return raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func formEncode(_ fields: [String: String]) -> String {
        fields
            .map { key, value in
                let k = key.addingPercentEncoding(withAllowedCharacters: Self.formAllowedCharacters) ?? key
                let v = value.addingPercentEncoding(withAllowedCharacters: Self.formAllowedCharacters) ?? value
                return "\(k)=\(v)"
            }
            .joined(separator: "&")
    }
}
