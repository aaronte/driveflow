import Foundation
import AppKit

/// Short-lived service-account access token plus the public share email. No SA JSON key in the app.
@MainActor
final class DriveAccessSession: ObservableObject, AccessTokenProviding {
    enum Screen: Equatable {
        case needsFolder
        case browsing
        case addingFolder
    }

    @Published private(set) var shareEmail: String?
    @Published private(set) var screen: Screen = .needsFolder
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

    var showsShareSetup: Bool { screen != .browsing }

    var canDismissAddFolder: Bool { screen == .addingFolder }

    func bootstrap(buyerEmail: String) async {
        lastError = nil
        self.buyerEmail = buyerEmail
        reloadBoundFoldersFromStore()
        restoreCachedShareEmail(for: buyerEmail)

        do {
            try await refreshShareSession(buyerEmail: buyerEmail)
        } catch let error as AppError {
            guard self.buyerEmail != nil else { return }
            lastError = error
            if boundFolderIDs.isEmpty {
                screen = .needsFolder
            }
        } catch {
            guard self.buyerEmail != nil else { return }
            lastError = .network(error.localizedDescription)
            if boundFolderIDs.isEmpty {
                screen = .needsFolder
            }
        }
    }

    /// Call after Google identity sign-in / restore when a license payload already
    /// included share credentials (extended license check).
    func applyPrefetchedSession(_ session: ShareMintClient.Session, buyerEmail: String) async {
        self.buyerEmail = buyerEmail
        reloadBoundFoldersFromStore()
        restoreCachedShareEmail(for: buyerEmail)
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
        // The mint task outlives a cancelled waiter. Sign-out cancels `refreshTask` itself.
        let task = Task { @MainActor in
            defer {
                if self.refreshSerial == serial {
                    self.refreshTask = nil
                }
            }
            try await self.performRefresh(buyerEmail: buyerEmail, epochAtStart: started)
        }
        refreshTask = task
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

    nonisolated static func surfacingTokenFailure(_ error: Error) -> AppError {
        if let error = error as? AppError { return error }
        return .network(error.localizedDescription)
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
        screen = boundFolderIDs.isEmpty ? .needsFolder : .addingFolder
        lastError = nil
        unauthorizedRetry.clear()
        mutateOnboarding { $0.resetForNewFolder() }
        stopPolling()
    }

    func dismissAddFolder() {
        guard screen == .addingFolder else { return }
        screen = .browsing
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
        screen = .needsFolder
        onboarding = ShareOnboarding()
        lastError = nil
        authenticationFailure = nil
    }

    func noteUnrecoverableDriveAuth() {
        guard authenticationFailure == nil else { return }
        authenticationFailure = .tokenExpired
    }

    func refreshAfterUnauthorized() async throws {
        guard let buyerEmail else {
            throw AppError.tokenExpired
        }
        try await refreshShareSession(buyerEmail: buyerEmail)
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

    private func googleIDTokenForMint() async throws -> String {
        guard let idTokenProvider else {
            throw AppError.authFailed(
                "Sign in again so Driveflow can verify your Google account before opening Drive."
            )
        }
        return try await idTokenProvider()
    }

    private func mutateOnboarding(_ body: (inout ShareOnboarding) -> Void) {
        var copy = onboarding
        body(&copy)
        onboarding = copy
    }

    private func reloadBoundFoldersFromStore() {
        guard let buyerEmail else {
            boundFolderIDs = []
            screen = .needsFolder
            return
        }
        let records = BoundFolderStore.loadOrdered(buyerEmail: buyerEmail)
        boundFolderIDs = Set(records.map(\.id.raw))
        screen = boundFolderIDs.isEmpty ? .needsFolder : .browsing
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
            let probe: FolderProbe
            do {
                probe = try await probeFolder(id: folderID)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, pollSerial == serial, buyerEmail != nil else { return }
                let failure = Self.surfacingTokenFailure(error)
                lastError = failure
                if failure.requiresSignInAgain {
                    noteUnrecoverableDriveAuth()
                } else {
                    mutateOnboarding { $0.cancelWaiting() }
                }
                stopPolling()
                return
            }
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
                switch unauthorizedRetry.followUp {
                case .refresh:
                    unauthorizedRetry.markRefreshed()
                    if await refreshTokenForPoll() == false {
                        return
                    }
                case .sessionExpired:
                    noteUnrecoverableDriveAuth()
                    stopPolling()
                    return
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

    private func restoreCachedShareEmail(for buyerEmail: String) {
        let storedBuyer: String?
        do {
            storedBuyer = try CredentialStore.get(account: buyerEmailAccount)
        } catch {
            return
        }
        guard let storedBuyer,
              !storedBuyer.isEmpty,
              storedBuyer.compare(buyerEmail, options: .caseInsensitive) == .orderedSame
        else { return }
        let cached: String?
        do {
            cached = try CredentialStore.get(account: shareEmailAccount)
        } catch {
            return
        }
        let trimmed = cached?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return }
        shareEmail = trimmed
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
        } catch is CancellationError {
            return false
        } catch let error as AppError {
            guard self.buyerEmail != nil else { return false }
            lastError = error
            if error.requiresSignInAgain {
                noteUnrecoverableDriveAuth()
            } else {
                mutateOnboarding { $0.cancelWaiting() }
            }
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
        screen = .browsing
        stopPolling()
    }

    private func probeFolder(id: FolderID) async throws -> FolderProbe {
        let token: String
        do {
            token = try await validAccessToken()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.surfacingTokenFailure(error)
        }
        do {
            guard let url = filesGetURL(folderID: id) else { return .notReadableYet }
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            return DriveFolderAccess.interpret(statusCode: status, body: json, pastedID: id)
        } catch is CancellationError {
            throw CancellationError()
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
