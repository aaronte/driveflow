import Foundation
import AppKit

/// Short-lived service-account access token plus the public share email. No SA JSON key in the app.
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

    var idTokenProvider: (() async throws -> String)?

    private let accessAccount = "drive.sa.access"
    private let expiryAccount = "drive.sa.expiry"
    private let shareEmailAccount = "drive.sa.email"
    private let buyerEmailAccount = "drive.sa.buyer"

    private var buyerEmail: String?
    private var pollTask: Task<Void, Never>?
    private var pollSerial = 0
    private var refreshTask: Task<Void, Error>?
    private var refreshSerial = 0
    private var epoch = 0
    private var unauthorizedRetry = UnauthorizedRetry()
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
            guard self.buyerEmail != nil else { return }
            lastError = error
            if boundFolderIDs.isEmpty {
                isReady = false
            }
        } catch {
            guard self.buyerEmail != nil else { return }
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
        let started = epoch
        if let existing = refreshTask {
            try await awaitRefresh(existing, started: started)
            return
        }
        let serial = refreshSerial
        let task = Task { @MainActor in
            try await self.performRefresh(buyerEmail: buyerEmail, epochAtStart: started)
        }
        refreshTask = task
        defer {
            if refreshSerial == serial {
                refreshTask = nil
            }
        }
        try await awaitRefresh(task, started: started)
    }

    private func awaitRefresh(_ task: Task<Void, Error>, started: Int) async throws {
        do {
            try await task.value
        } catch is CancellationError {
            guard epoch == started else { return }
            throw CancellationError()
        }
    }

    private func performRefresh(buyerEmail: String, epochAtStart: Int) async throws {
        guard epoch == epochAtStart else { return }
        isBusy = true
        defer {
            if epoch == epochAtStart {
                isBusy = false
            }
        }
        do {
            let idToken = try await googleIDTokenForMint()
            guard epoch == epochAtStart else { return }
            let session = try await ShareMintClient.mint(googleIDToken: idToken)
            guard epoch == epochAtStart else { return }
            try persist(session: session, buyerEmail: buyerEmail)
            shareEmail = session.shareEmail
            self.buyerEmail = buyerEmail
        } catch let error as AppError {
            guard epoch == epochAtStart else { return }
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
                unauthorizedRetry.clear()
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
            unauthorizedRetry.clear()
            startPolling()
        }
    }

    func openSharingInDrive() {
        guard let folderID = onboarding.recognizedFolderID else { return }
        NSWorkspace.shared.open(DriveFolderLink.sharingURL(folderID: folderID))
        mutateOnboarding { $0.openSharingTapped() }
        if onboarding.isWaiting {
            unauthorizedRetry.clear()
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
        unauthorizedRetry.clear()
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
        guard let buyerEmail, let folderID = FolderID(id) else { return }
        BoundFolderStore.updateName(id: folderID, name: name, buyerEmail: buyerEmail)
    }

    func clear() {
        epoch += 1
        refreshSerial += 1
        refreshTask?.cancel()
        refreshTask = nil
        unauthorizedRetry.clear()
        isBusy = false
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
        boundFolderIDs = Set(records.map(\.id.raw))
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
        pollSerial += 1
        let serial = pollSerial
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            await self?.pollForFolderAccess(serial: serial)
        }
    }

    private func stopPolling() {
        pollSerial += 1
        pollTask?.cancel()
        pollTask = nil
    }

    private func pollForFolderAccess(serial: Int) async {
        while !Task.isCancelled, pollSerial == serial {
            guard let folderID = onboarding.pollTargetID else { return }
            let probe = await probeFolder(id: folderID)
            guard !Task.isCancelled, pollSerial == serial else { return }
            guard onboarding.pollTargetID == folderID else { continue }

            let action = applyProbe(probe)
            guard !Task.isCancelled, pollSerial == serial else { return }
            switch action {
            case .idle:
                return
            case .pollAgain:
                unauthorizedRetry.clear()
            case .refreshToken:
                if unauthorizedRetry.shouldRefresh {
                    unauthorizedRetry.markRefreshed()
                    if await refreshTokenForPoll() == false {
                        return
                    }
                }
            case .bind(let id, let name):
                guard buyerEmail != nil, pollSerial == serial else { return }
                commitBind(id: id, name: name)
                return
            case .showNotAFolder:
                lastError = nil
                stopPolling()
                return
            }
            do {
                try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
            } catch {
                return
            }
        }
    }

    private func applyProbe(_ probe: FolderProbe) -> ShareBindAction {
        var copy = onboarding
        let action = copy.apply(probe: probe)
        onboarding = copy
        return action
    }

    private func refreshTokenForPoll() async -> Bool {
        guard let buyerEmail else { return false }
        do {
            try await refreshShareSession(buyerEmail: buyerEmail)
            return onboarding.isWaiting
        } catch let error as AppError {
            guard self.buyerEmail != nil else { return false }
            lastError = error
            mutateOnboarding { $0.cancelWaiting() }
            stopPolling()
            return false
        } catch {
            guard self.buyerEmail != nil else { return false }
            lastError = .network(error.localizedDescription)
            mutateOnboarding { $0.cancelWaiting() }
            stopPolling()
            return false
        }
    }

    private func commitBind(id: FolderID, name: String) {
        guard let buyerEmail else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        BoundFolderStore.bind(
            BoundFolderRecord(id: id, name: trimmed.isEmpty ? nil : trimmed),
            buyerEmail: buyerEmail
        )
        let records = BoundFolderStore.loadOrdered(buyerEmail: buyerEmail)
        boundFolderIDs = Set(records.map(\.id.raw))
        preferredFolderID = id.raw
        isReady = true
        isPresentingAddFolder = false
        stopPolling()
    }

    private func probeFolder(id: FolderID) async -> FolderProbe {
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

    private func filesGetURL(folderID: FolderID) -> URL? {
        guard var components = URLComponents(
            url: AppConfig.driveAPIBase
                .appendingPathComponent("files")
                .appendingPathComponent(folderID.raw),
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
