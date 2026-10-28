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
    @Published private(set) var isPresentingAddFolder = false
    @Published private(set) var isBusy = false
    @Published private(set) var boundFolderIDs: Set<String> = []
    @Published private(set) var preferredFolderID: String?
    @Published private(set) var onboarding = ShareOnboarding()
    @Published var lastError: AppError?
    /// Set when the mint server requires a new Google sign-in (401) or a license (402).
    @Published private(set) var authenticationFailure: AppError?

    /// Supplies the buyer’s Google ID token when the production mint URL is set.
    var idTokenProvider: (() async throws -> String)?

    private let accessAccount = "drive.sa.access"
    private let expiryAccount = "drive.sa.expiry"
    private let shareEmailAccount = "drive.sa.email"
    private let buyerEmailAccount = "drive.sa.buyer"

    private var buyerEmail: String?
    private var pollTask: Task<Void, Never>?
    private var didRefreshForPoll = false
    private let pollIntervalNanoseconds: UInt64 = 3_000_000_000

    var hasShareEmail: Bool { shareEmail?.isEmpty == false }

    var showsShareSetup: Bool { !isReady || isPresentingAddFolder }

    var canDismissAddFolder: Bool { isReady && isPresentingAddFolder }

    func bootstrap(buyerEmail: String) async {
        lastError = nil
        self.buyerEmail = buyerEmail
        reloadBoundFoldersFromStore()
        isPresentingAddFolder = false

        do {
            try await refreshShareSession(buyerEmail: buyerEmail)
        } catch let error as AppError {
            lastError = error
            if boundFolderIDs.isEmpty {
                isReady = false
            }
        } catch {
            lastError = .network(error.localizedDescription)
            if boundFolderIDs.isEmpty {
                isReady = false
            }
        }
    }

    /// Call after Google identity sign-in / restore when a license payload already
    /// included share credentials (extended license check).
    func applyPrefetchedSession(_ session: ShareMintClient.Session, buyerEmail: String) async {
        self.buyerEmail = buyerEmail
        reloadBoundFoldersFromStore()
        do {
            try persist(session: session, buyerEmail: buyerEmail)
            shareEmail = session.shareEmail
            lastError = nil
        } catch {
            lastError = .unknown(error.localizedDescription)
        }
    }

    func refreshShareSession(buyerEmail: String) async throws {
        isBusy = true
        defer { isBusy = false }
        do {
            let idToken = try await googleIDTokenForMint()
            let session = try await ShareMintClient.mint(googleIDToken: idToken)
            try persist(session: session, buyerEmail: buyerEmail)
            shareEmail = session.shareEmail
            self.buyerEmail = buyerEmail
        } catch let error as AppError {
            let surfaced = Self.surfacing(error, buyerEmail: buyerEmail)
            if surfaced.requiresSignInAgain {
                authenticationFailure = surfaced
            }
            throw surfaced
        }
    }

    nonisolated static func surfacing(_ error: AppError, buyerEmail: String) -> AppError {
        if case .licenseRequired(let email) = error, email == nil || email?.isEmpty == true {
            return .licenseRequired(email: buyerEmail)
        }
        return error
    }

    func updateFolderLink(_ raw: String) {
        if raw == onboarding.linkText { return }
        let previousTarget = onboarding.pollTargetID
        let wasWaiting = onboarding.isWaiting
        mutateOnboarding { $0.setLink(raw) }
        if onboarding.isWaiting {
            if onboarding.pollTargetID != previousTarget || !wasWaiting {
                didRefreshForPoll = false
                startPolling()
            }
        } else if wasWaiting {
            stopPolling()
        }
    }

    func copyShareEmailToPasteboard() {
        guard let shareEmail, !shareEmail.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(shareEmail, forType: .string)
        mutateOnboarding { $0.copyTapped() }
        if onboarding.isWaiting {
            didRefreshForPoll = false
            startPolling()
        }
    }

    func openSharingInDrive() {
        guard let folderID = onboarding.recognizedFolderID,
              let url = DriveFolderLink.sharingURL(folderID: folderID)
        else { return }
        NSWorkspace.shared.open(url)
        mutateOnboarding { $0.openSharingTapped() }
        if onboarding.isWaiting {
            didRefreshForPoll = false
            startPolling()
        }
    }

    func cancelWaitingForAccess() {
        mutateOnboarding { $0.cancelWaiting() }
        stopPolling()
    }

    func presentAddFolder() {
        isPresentingAddFolder = true
        lastError = nil
        didRefreshForPoll = false
        mutateOnboarding { $0.resetForNewFolder() }
        stopPolling()
    }

    func dismissAddFolder() {
        guard isReady else { return }
        isPresentingAddFolder = false
        lastError = nil
        mutateOnboarding { $0.resetForNewFolder() }
        stopPolling()
    }

    func orderedBoundFolders() -> [BoundFolderRecord] {
        guard let buyerEmail else { return [] }
        return BoundFolderStore.loadOrdered(buyerEmail: buyerEmail)
    }

    func rememberFolderName(id: String, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let buyerEmail, !trimmed.isEmpty else { return }
        var records = BoundFolderStore.loadOrdered(buyerEmail: buyerEmail)
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        guard records[index].name != trimmed else { return }
        records[index].name = trimmed
        BoundFolderStore.save(records, buyerEmail: buyerEmail)
    }

    func clear() {
        stopPolling()
        // Bound folders stay on disk per buyer email so re-sign-in keeps them.
        CredentialStore.delete(account: accessAccount)
        CredentialStore.delete(account: expiryAccount)
        CredentialStore.delete(account: shareEmailAccount)
        CredentialStore.delete(account: buyerEmailAccount)
        shareEmail = nil
        buyerEmail = nil
        boundFolderIDs = []
        preferredFolderID = nil
        isReady = false
        isPresentingAddFolder = false
        onboarding = ShareOnboarding()
        lastError = nil
        authenticationFailure = nil
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

    private func googleIDTokenForMint() async throws -> String? {
        if AppConfig.shareMintURL != nil {
            guard let idTokenProvider else {
                throw AppError.authFailed(
                    "Sign in again so Driveflow can verify your Google account before opening Drive."
                )
            }
            return try await idTokenProvider()
        }
        return try? await idTokenProvider?()
    }

    private func mutateOnboarding(_ body: (inout ShareOnboarding) -> Void) {
        var copy = onboarding
        body(&copy)
        onboarding = copy
    }

    private func reloadBoundFoldersFromStore() {
        guard let buyerEmail else {
            boundFolderIDs = []
            isReady = false
            return
        }
        let records = BoundFolderStore.loadOrdered(buyerEmail: buyerEmail)
        boundFolderIDs = Set(records.map(\.id))
        isReady = !boundFolderIDs.isEmpty
    }

    private func persist(session: ShareMintClient.Session, buyerEmail: String) throws {
        try CredentialStore.set(session.accessToken, account: accessAccount)
        try CredentialStore.set(String(session.expiresAt.timeIntervalSince1970), account: expiryAccount)
        try CredentialStore.set(session.shareEmail, account: shareEmailAccount)
        try CredentialStore.set(buyerEmail, account: buyerEmailAccount)
    }

    private func startPolling() {
        guard onboarding.pollTargetID != nil else { return }
        lastError = nil
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            await self?.pollForFolderAccess()
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func pollForFolderAccess() async {
        while !Task.isCancelled {
            guard let folderID = onboarding.pollTargetID else { return }
            let probe = await probeFolder(id: folderID)
            if Task.isCancelled { return }
            guard onboarding.pollTargetID == folderID else { continue }

            let action = applyProbe(probe)
            switch action {
            case .idle:
                return
            case .pollAgain:
                break
            case .refreshToken:
                if await refreshTokenForPoll() == false {
                    return
                }
            case .bind(let id):
                let name = onboarding.boundNames[id]
                commitBind(id: id, name: name)
                return
            case .showNotAFolder:
                lastError = nil
                stopPolling()
                return
            }
            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
    }

    private func applyProbe(_ probe: FolderProbe) -> ShareBindAction {
        var copy = onboarding
        let action = copy.apply(probe: probe)
        onboarding = copy
        return action
    }

    /// Returns false when waiting should stop.
    private func refreshTokenForPoll() async -> Bool {
        guard !didRefreshForPoll else { return true }
        didRefreshForPoll = true
        guard let buyerEmail else { return false }
        do {
            try await refreshShareSession(buyerEmail: buyerEmail)
            return onboarding.isWaiting
        } catch let error as AppError {
            lastError = error
            mutateOnboarding { $0.cancelWaiting() }
            stopPolling()
            return false
        } catch {
            lastError = .network(error.localizedDescription)
            mutateOnboarding { $0.cancelWaiting() }
            stopPolling()
            return false
        }
    }

    private func commitBind(id: String, name: String?) {
        guard let buyerEmail else { return }
        var records = BoundFolderStore.loadOrdered(buyerEmail: buyerEmail)
        if let index = records.firstIndex(where: { $0.id == id }) {
            if let name, !name.isEmpty {
                records[index].name = name
            }
        } else {
            records.append(BoundFolderRecord(id: id, name: name))
        }
        BoundFolderStore.save(records, buyerEmail: buyerEmail)
        boundFolderIDs = Set(records.map(\.id))
        preferredFolderID = id
        isReady = true
        isPresentingAddFolder = false
        stopPolling()
    }

    private func probeFolder(id: String) async -> FolderProbe {
        do {
            let token = try await validAccessToken()
            guard let url = filesGetURL(folderID: id) else { return .notReadableYet }
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            return DriveFolderAccess.interpret(statusCode: status, body: json, pastedID: id)
        } catch {
            return .notReadableYet
        }
    }

    private func filesGetURL(folderID: String) -> URL? {
        guard var components = URLComponents(
            url: AppConfig.driveAPIBase
                .appendingPathComponent("files")
                .appendingPathComponent(folderID),
            resolvingAgainstBaseURL: false
        ) else { return nil }
        components.queryItems = [
            URLQueryItem(
                name: "fields",
                value: "id,name,mimeType,shortcutDetails(targetId,targetMimeType)"
            ),
            URLQueryItem(name: "supportsAllDrives", value: "true"),
        ]
        return components.url
    }
}
