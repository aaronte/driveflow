import XCTest
@testable import Driveflow

final class ShareRecoveryTests: XCTestCase {
    private let folderID = "1AbC9xQ2kLm7RtVz-4hJpW0sYeN3uF"
    private let otherFolderID = "1ZzQ9xQ2kLm7RtVz-4hJpW0sYeN3uF"

    func testMintFailureIsNotReportedAsFolderNotShared() {
        let minted = DriveAccessSession.surfacingTokenFailure(AppError.shareMintFailed)
        guard case .shareMintFailed = minted else {
            return XCTFail("500 mint failure must stay a mint failure")
        }
        XCTAssertFalse(minted.requiresSignInAgain)

        let rejected = DriveAccessSession.surfacingTokenFailure(AppError.shareMintUnauthorized)
        guard case .shareMintUnauthorized = rejected else {
            return XCTFail("401 mint failure must stay unauthorized")
        }
        XCTAssertTrue(rejected.requiresSignInAgain)

        struct Offline: Error {}
        guard case .network = DriveAccessSession.surfacingTokenFailure(Offline()) else {
            return XCTFail("a non-app error becomes a network failure")
        }
    }

    @MainActor
    func testASecondDriveRejectionEndsTheSession() {
        let session = DriveAccessSession()
        XCTAssertNil(session.authenticationFailure)
        session.noteUnrecoverableDriveAuth()
        XCTAssertEqual(
            session.authenticationFailure?.requiresSignInAgain,
            true
        )
        let message = session.authenticationFailure?.localizedDescription
        session.noteUnrecoverableDriveAuth()
        XCTAssertEqual(session.authenticationFailure?.localizedDescription, message)
    }

    func testBuyerEmailsThatShareAnAtEncodingStaySeparate() {
        let suffix = UUID().uuidString.lowercased()
        let first = "a-\(suffix)@b_at_c.com"
        let second = "a-\(suffix)_at_b@c.com"
        defer {
            BoundFolderStore.clear(buyerEmail: first)
            BoundFolderStore.clear(buyerEmail: second)
        }
        let firstFolder = FolderID(folderID)!
        let secondFolder = FolderID(otherFolderID)!
        BoundFolderStore.bind(
            BoundFolderRecord(id: firstFolder, name: "A"),
            buyerEmail: first
        )
        BoundFolderStore.bind(
            BoundFolderRecord(id: secondFolder, name: "B"),
            buyerEmail: second
        )
        XCTAssertEqual(BoundFolderStore.load(buyerEmail: first), [firstFolder])
        XCTAssertEqual(BoundFolderStore.load(buyerEmail: second), [secondFolder])
    }

    func testSignOutRemovesALegacyTokenFromTheFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("driveflow-legacy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        CredentialStore.testingLegacyDirectory = directory
        CredentialStore.testingKeychainService = "test.driveflow.\(UUID().uuidString)"
        defer {
            CredentialStore.delete(account: "gate.refresh")
            CredentialStore.delete(account: "gate.access")
            CredentialStore.testingLegacyDirectory = nil
            CredentialStore.testingKeychainService = nil
            try? FileManager.default.removeItem(at: directory)
        }

        let url = directory.appendingPathComponent("session.tokens")
        let original: [String: String] = [
            "gate.refresh": "refresh-secret",
            "gate.access": "access-secret",
        ]
        try JSONSerialization.data(withJSONObject: original).write(to: url)

        CredentialStore.delete(account: "gate.refresh")
        CredentialStore.delete(account: "gate.refresh")

        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            let json = try XCTUnwrap(
                JSONSerialization.jsonObject(with: data) as? [String: String]
            )
            XCTAssertNil(json["gate.refresh"])
            XCTAssertEqual(json["gate.access"], "access-secret")
        } else {
            XCTAssertNil(try CredentialStore.get(account: "gate.refresh"))
        }
    }

    func testRcloneConnectionStringQuotesTheTokenJSON() {
        let token = #"{"access_token":"ya29.abc","token_type":"Bearer","expiry":"2026-10-28T18:11:00Z"}"#
        let remote = RcloneDriveRemote.fsString(
            tokenJSON: token,
            extra: "root_folder_id=\(folderID)"
        )
        let prefix = ":drive,scope=drive.readonly,token='"
        let suffix = "',root_folder_id=\(folderID):"
        XCTAssertTrue(remote.hasPrefix(prefix))
        XCTAssertTrue(remote.hasSuffix(suffix))
        XCTAssertEqual(
            String(remote.dropFirst(prefix.count).dropLast(suffix.count)),
            token
        )
        XCTAssertFalse(remote.contains("--drive-token"))
    }

    func testRcloneConnectionStringDoublesApostrophesInsideTheToken() {
        let remote = RcloneDriveRemote.fsString(
            tokenJSON: #"{"access_token":"it's"}"#,
            extra: nil
        )
        XCTAssertEqual(
            remote,
            #":drive,scope=drive.readonly,token='{"access_token":"it''s"}':"#
        )
    }

    func testRcloneErrorsDoNotKeepTheAccessToken() {
        let leaked = #"Failed to create file system for ":drive,token='{"access_token":"ya29.SUPERSECRET","token_type":"Bearer"}'": 401"#
        let scrubbed = RcloneSecretText.scrubbingCredentials(leaked)
        XCTAssertFalse(scrubbed.contains("ya29.SUPERSECRET"))
        XCTAssertFalse(scrubbed.contains("SUPERSECRET"))
        XCTAssertTrue(scrubbed.contains("Failed to create file system"))

        let bare = RcloneSecretText.scrubbingCredentials("rejected ya29.abc_DEF-1")
        XCTAssertFalse(bare.contains("ya29."))
        XCTAssertTrue(bare.contains("rejected"))
    }

    func testDrive401RetriesOnceWithTheRefreshedToken() async throws {
        ScriptedDriveHTTP.reset()
        ScriptedDriveHTTP.statuses = [401, 200]
        ScriptedDriveHTTP.bodies = [
            Data(),
            #"{"files":[{"id":"file-id-1234567890","name":"Shot.jpg","mimeType":"image/jpeg"}]}"#
                .data(using: .utf8)!,
        ]
        let token = ScriptedShareToken()
        let client = makeClient(token: token)
        let result = try await client.list(parentID: folderID)
        XCTAssertEqual(result.items.map(\.name), ["Shot.jpg"])
        XCTAssertEqual(token.refreshCount, 1)
        XCTAssertEqual(token.issued, ["first", "second"])
        XCTAssertEqual(ScriptedDriveHTTP.authorizations, ["Bearer first", "Bearer second"])
    }

    func testDrive401AfterRefreshSurfacesTokenExpired() async {
        ScriptedDriveHTTP.reset()
        ScriptedDriveHTTP.statuses = [401, 401]
        let token = ScriptedShareToken()
        let client = makeClient(token: token)
        do {
            _ = try await client.list(parentID: folderID)
            XCTFail("a second 401 should stop")
        } catch let error as AppError {
            guard case .tokenExpired = error else {
                return XCTFail("expected tokenExpired, got \(error)")
            }
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertEqual(token.refreshCount, 1)
        XCTAssertEqual(ScriptedDriveHTTP.authorizations.count, 2)
    }

    func testDrive401DoesNotRetryWhenMintFails() async {
        ScriptedDriveHTTP.reset()
        ScriptedDriveHTTP.statuses = [401, 200]
        let token = ScriptedShareToken()
        token.refreshError = .shareMintFailed
        let client = makeClient(token: token)
        do {
            _ = try await client.list(parentID: folderID)
            XCTFail("mint failure should surface")
        } catch let error as AppError {
            guard case .shareMintFailed = error else {
                return XCTFail("expected shareMintFailed, got \(error)")
            }
            XCTAssertFalse(error.requiresSignInAgain)
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertEqual(token.refreshCount, 1)
        XCTAssertEqual(ScriptedDriveHTTP.authorizations, ["Bearer first"])
    }

    private func makeClient(token: ScriptedShareToken) -> DriveClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScriptedDriveHTTP.self]
        return DriveClient(tokenProvider: token, session: URLSession(configuration: configuration))
    }
}

private final class ScriptedShareToken: AccessTokenProviding {
    var current = "first"
    var refreshCount = 0
    var refreshError: AppError?
    private(set) var issued: [String] = []

    func validAccessToken() async throws -> String {
        issued.append(current)
        return current
    }

    func refreshAfterUnauthorized() async throws {
        refreshCount += 1
        if let refreshError {
            throw refreshError
        }
        current = "second"
    }
}

private final class ScriptedDriveHTTP: URLProtocol {
    static var statuses: [Int] = []
    static var bodies: [Data] = []
    static var authorizations: [String] = []
    private static var index = 0

    static func reset() {
        statuses = []
        bodies = []
        authorizations = []
        index = 0
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let status = Self.statuses.indices.contains(Self.index) ? Self.statuses[Self.index] : 500
        let body = Self.bodies.indices.contains(Self.index) ? Self.bodies[Self.index] : Data()
        Self.authorizations.append(request.value(forHTTPHeaderField: "Authorization") ?? "")
        Self.index += 1
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
              )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
