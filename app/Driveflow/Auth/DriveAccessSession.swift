import Foundation
import AppKit

/// Drive identity for browse/download: a Google Cloud service account principal.
///
/// The Mac app never embeds a long-lived SA JSON key. It holds a short-lived
/// access token (mint API, or local/dev SA key / env token) plus the public
/// share email shown to the user.
@MainActor
final class DriveAccessSession: ObservableObject, AccessTokenProviding {
    @Published private(set) var shareEmail: String?
    @Published private(set) var isReady = false
    @Published private(set) var isWaitingForShare = false
    @Published private(set) var isBusy = false
    @Published private(set) var boundFolderIDs: Set<String> = []
    @Published var lastError: AppError?
    @Published private(set) var didCopyShareEmail = false

    private let accessAccount = "drive.sa.access"
    private let expiryAccount = "drive.sa.expiry"
    private let shareEmailAccount = "drive.sa.email"
    private let buyerEmailAccount = "drive.sa.buyer"

    private var buyerEmail: String?
    private var pollTask: Task<Void, Never>?
    private let pollIntervalNanoseconds: UInt64 = 3_000_000_000

    var hasShareEmail: Bool { shareEmail?.isEmpty == false }

    func bootstrap(buyerEmail: String) async {
        lastError = nil
        self.buyerEmail = buyerEmail
        boundFolderIDs = BoundFolderStore.load(buyerEmail: buyerEmail)
        isReady = !boundFolderIDs.isEmpty

        do {
            try await refreshShareSession(buyerEmail: buyerEmail)
            if isReady {
                isWaitingForShare = false
            }
        } catch let error as AppError {
            lastError = error
            isReady = false
        } catch {
            lastError = .network(error.localizedDescription)
            isReady = false
        }
    }

    /// Call after Google identity sign-in / restore when a license payload already
    /// included share credentials (extended license check).
    func applyPrefetchedSession(_ session: ShareMintClient.Session, buyerEmail: String) async {
        self.buyerEmail = buyerEmail
        boundFolderIDs = BoundFolderStore.load(buyerEmail: buyerEmail)
        do {
            try persist(session: session, buyerEmail: buyerEmail)
            shareEmail = session.shareEmail
            isReady = !boundFolderIDs.isEmpty
            lastError = nil
        } catch {
            lastError = .unknown(error.localizedDescription)
        }
    }

    func refreshShareSession(buyerEmail: String) async throws {
        isBusy = true
        defer { isBusy = false }
        let session = try await ShareMintClient.mint(buyerEmail: buyerEmail)
        try persist(session: session, buyerEmail: buyerEmail)
        shareEmail = session.shareEmail
        self.buyerEmail = buyerEmail
    }

    func copyShareEmailToPasteboard() {
        guard let shareEmail, !shareEmail.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(shareEmail, forType: .string)
        didCopyShareEmail = true
        startWaitingForShare()
    }

    func startWaitingForShare() {
        isWaitingForShare = true
        lastError = nil
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            await self?.pollForSharedItems()
        }
    }

    func stopWaitingForShare() {
        pollTask?.cancel()
        pollTask = nil
        isWaitingForShare = false
    }

    /// Bind currently shared roots for this buyer, then enter the browser.
    func bindVisibleSharesAndEnter() async {
        do {
            let ids = try await fetchSharedWithMeRootIDs()
            guard !ids.isEmpty else {
                lastError = .waitingForShare
                return
            }
            bind(ids: ids)
        } catch let error as AppError {
            lastError = error
        } catch {
            lastError = .driveAPI(error.localizedDescription)
        }
    }

    func bind(ids: Set<String>) {
        guard let buyerEmail else { return }
        boundFolderIDs.formUnion(ids)
        BoundFolderStore.save(boundFolderIDs, buyerEmail: buyerEmail)
        isReady = !boundFolderIDs.isEmpty
        if isReady {
            stopWaitingForShare()
        }
    }

    func clear() {
        stopWaitingForShare()
        // Bound folders stay on disk per buyer email so re-sign-in keeps isolation.
        CredentialStore.delete(account: accessAccount)
        CredentialStore.delete(account: expiryAccount)
        CredentialStore.delete(account: shareEmailAccount)
        CredentialStore.delete(account: buyerEmailAccount)
        shareEmail = nil
        buyerEmail = nil
        boundFolderIDs = []
        isReady = false
        didCopyShareEmail = false
        lastError = nil
    }

    // MARK: - AccessTokenProviding

    func validAccessToken() async throws -> String {
        if let expiryString = try CredentialStore.get(account: expiryAccount),
           let expiry = TimeInterval(expiryString),
           Date().timeIntervalSince1970 < expiry - 60,
           let token = try CredentialStore.get(account: accessAccount),
           !token.isEmpty {
            return token
        }
        guard let buyerEmail else {
            throw AppError.tokenExpired
        }
        try await refreshShareSession(buyerEmail: buyerEmail)
        guard let token = try CredentialStore.get(account: accessAccount), !token.isEmpty else {
            throw AppError.tokenExpired
        }
        return token
    }

    /// rclone-compatible OAuth token JSON (access token only — no SA private key).
    func rcloneTokenJSON() async throws -> String {
        let access = try await validAccessToken()
        let expiryDate: Date
        if let expiryString = try? CredentialStore.get(account: expiryAccount),
           let expiry = TimeInterval(expiryString) {
            expiryDate = Date(timeIntervalSince1970: expiry)
        } else {
            expiryDate = Date().addingTimeInterval(3500)
        }
        let payload: [String: Any] = [
            "access_token": access,
            "token_type": "Bearer",
            "expiry": ISO8601DateFormatter().string(from: expiryDate),
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    // MARK: - Private

    private func persist(session: ShareMintClient.Session, buyerEmail: String) throws {
        try CredentialStore.set(session.accessToken, account: accessAccount)
        try CredentialStore.set(String(session.expiresAt.timeIntervalSince1970), account: expiryAccount)
        try CredentialStore.set(session.shareEmail, account: shareEmailAccount)
        try CredentialStore.set(buyerEmail, account: buyerEmailAccount)
    }

    private func pollForSharedItems() async {
        while !Task.isCancelled {
            do {
                let allIDs = try await fetchSharedWithMeRootIDs()
                let known = boundFolderIDs
                let fresh = allIDs.subtracting(known)
                let candidates = known.isEmpty ? allIDs : fresh
                if !candidates.isEmpty {
                    bind(ids: candidates)
                    return
                }
            } catch {
                // Soft-fail polling — keep waiting until the user cancels or shares.
            }
            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
    }

    /// Unfiltered Shared-with-me root IDs (for onboarding bind / poll).
    private func fetchSharedWithMeRootIDs() async throws -> Set<String> {
        let token = try await validAccessToken()
        var components = URLComponents(
            url: AppConfig.driveAPIBase.appendingPathComponent("files"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "q", value: "sharedWithMe = true and trashed = false"),
            URLQueryItem(name: "pageSize", value: "100"),
            URLQueryItem(name: "fields", value: "files(id)"),
            URLQueryItem(name: "supportsAllDrives", value: "true"),
            URLQueryItem(name: "includeItemsFromAllDrives", value: "true"),
        ]
        guard let url = components.url else {
            throw AppError.driveAPI("Invalid Shared-with-me query URL.")
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AppError.network("No response from Drive.")
        }
        if http.statusCode == 401 {
            throw AppError.tokenExpired
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw AppError.driveAPI(body)
        }
        let json = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let files = json["files"] as? [[String: Any]] ?? []
        return Set(files.compactMap { $0["id"] as? String })
    }
}
