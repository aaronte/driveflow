import XCTest
@testable import Driveflow

final class ShareAccessTests: XCTestCase {
    private let folderID = "1AbC9xQ2kLm7RtVz-4hJpW0sYeN3uF"
    private let shortcutTargetID = "1ZzQ9xQ2kLm7RtVz-4hJpW0sYeN3uF"
    private var folder: FolderID { FolderID(folderID)! }
    private var shortcutTarget: FolderID { FolderID(shortcutTargetID)! }

    func testParsesCommonFolderLinks() {
        let samples = [
            "https://drive.google.com/drive/folders/\(folderID)",
            "https://drive.google.com/drive/folders/\(folderID)/",
            "https://drive.google.com/drive/folders/\(folderID)?usp=sharing",
            "https://drive.google.com/drive/folders/\(folderID)?usp=drive_link",
            "https://drive.google.com/drive/u/0/folders/\(folderID)",
            "https://drive.google.com/drive/u/1/folders/\(folderID)?resourcekey=0-abc",
            "https://drive.google.com/drive/mobile/folders/\(folderID)",
            "http://drive.google.com/drive/folders/\(folderID)",
            "https://drive.google.com/open?id=\(folderID)",
            "https://drive.google.com/folderview?id=\(folderID)",
            "https://drive.google.com/embeddedfolderview?id=\(folderID)&usp=sharing",
            "  https://drive.google.com/drive/folders/\(folderID)  ",
            "drive.google.com/drive/folders/\(folderID)",
            folderID,
        ]
        for sample in samples {
            XCTAssertEqual(
                DriveFolderLink.interpret(sample),
                .recognized(folderID: folder),
                sample
            )
        }
    }

    func testFileLinksAreRejected() {
        let samples = [
            "https://drive.google.com/file/d/\(folderID)/view",
            "https://drive.google.com/file/d/\(folderID)",
            "https://docs.google.com/document/d/\(folderID)/edit",
            "https://docs.google.com/spreadsheets/d/\(folderID)",
            "https://docs.google.com/presentation/d/\(folderID)/edit",
        ]
        for sample in samples {
            XCTAssertEqual(DriveFolderLink.interpret(sample), .fileLink, sample)
        }
    }

    func testUnrecognizedAndEmptyLinks() {
        XCTAssertEqual(DriveFolderLink.interpret(""), .empty)
        XCTAssertEqual(DriveFolderLink.interpret("   "), .empty)
        XCTAssertEqual(
            DriveFolderLink.interpret("https://example.com/drive/folders/\(folderID)"),
            .unrecognized
        )
        XCTAssertEqual(DriveFolderLink.interpret("not a link"), .unrecognized)
        XCTAssertEqual(
            DriveFolderLink.interpret("https://drive.google.com/drive/my-drive"),
            .unrecognized
        )
        XCTAssertEqual(DriveFolderLink.interpret("short"), .unrecognized)
    }

    func testSharingURLUsesPastedFolderID() {
        XCTAssertEqual(
            DriveFolderLink.sharingURL(folderID: folder).absoluteString,
            "https://drive.google.com/drive/folders/\(folderID)"
        )
        XCTAssertNil(FolderID("not an id"))
    }

    func testProbeKeepsWaitingWhenTheFolderIsNotSharedYet() {
        XCTAssertEqual(
            DriveFolderAccess.interpret(statusCode: 404, body: ["error": "notFound"], pastedID: folder),
            .notReadableYet
        )
        XCTAssertEqual(
            DriveFolderAccess.interpret(statusCode: 403, body: nil, pastedID: folder),
            .notReadableYet
        )
        XCTAssertEqual(
            DriveFolderAccess.interpret(statusCode: 500, body: nil, pastedID: folder),
            .notReadableYet
        )
    }

    func testProbeBindsThePastedFolderOnceItIsReadable() {
        let probe = DriveFolderAccess.interpret(
            statusCode: 200,
            body: [
                "id": folderID,
                "name": "Client Photos 2026",
                "mimeType": "application/vnd.google-apps.folder",
            ],
            pastedID: folder
        )
        XCTAssertEqual(
            probe,
            .readable(bindID: folder, name: "Client Photos 2026")
        )
    }

    func testProbeRejectsAReadableFile() {
        let probe = DriveFolderAccess.interpret(
            statusCode: 200,
            body: [
                "id": folderID,
                "name": "Shot list.pdf",
                "mimeType": "application/pdf",
            ],
            pastedID: folder
        )
        XCTAssertEqual(probe, .notAFolder)
    }

    func testProbeBindsShortcutTargetFolder() {
        let probe = DriveFolderAccess.interpret(
            statusCode: 200,
            body: [
                "id": folderID,
                "name": "Client Photos 2026",
                "mimeType": "application/vnd.google-apps.shortcut",
                "shortcutDetails": [
                    "targetId": shortcutTargetID,
                    "targetMimeType": "application/vnd.google-apps.folder",
                ],
            ],
            pastedID: folder
        )
        XCTAssertEqual(
            probe,
            .readable(bindID: shortcutTarget, name: "Client Photos 2026")
        )
    }

    func testUnauthorizedProbeAsksForATokenRefresh() {
        XCTAssertEqual(
            DriveFolderAccess.interpret(statusCode: 401, body: nil, pastedID: folder),
            .unauthorized
        )
    }

    func testWaitingDoesNotBindUntilTheFolderIsReadable() {
        var flow = ShareOnboarding()
        flow.setLink("https://drive.google.com/drive/folders/\(folderID)")
        XCTAssertFalse(flow.isWaiting)
        XCTAssertEqual(flow.status, .recognized(folderID: folder))
        XCTAssertEqual(flow.phase, .linkParsed(folder))

        flow.copyTapped()
        XCTAssertTrue(flow.isWaiting)
        XCTAssertEqual(flow.pollTargetID, folder)
        XCTAssertEqual(flow.phase, .waiting(folder))
        XCTAssertTrue(flow.didCopy)

        let stillWaiting = flow.apply(probe: .notReadableYet)
        XCTAssertEqual(stillWaiting, .pollAgain)
        XCTAssertTrue(flow.isWaiting)

        let bound = flow.apply(probe: .readable(bindID: folder, name: "Client Photos 2026"))
        XCTAssertEqual(bound, .bind(folderID: folder, name: "Client Photos 2026"))
        XCTAssertEqual(flow.phase, .bound(folder))
        XCTAssertFalse(flow.isWaiting)
        XCTAssertNil(flow.pollTargetID)
    }

    func testWaitingStartsWhenTheLinkArrivesAfterCopyOrOpen() {
        var copiedFirst = ShareOnboarding()
        copiedFirst.copyTapped()
        XCTAssertFalse(copiedFirst.isWaiting)
        copiedFirst.setLink("https://drive.google.com/drive/u/0/folders/\(folderID)?usp=sharing")
        XCTAssertEqual(copiedFirst.pollTargetID, folder)

        var openedFirst = ShareOnboarding()
        openedFirst.setLink(folderID)
        XCTAssertFalse(openedFirst.isWaiting)
        openedFirst.openSharingTapped()
        XCTAssertEqual(openedFirst.pollTargetID, folder)
    }

    func testCancelStopsPollingWithoutBinding() {
        var flow = ShareOnboarding()
        flow.setLink("https://drive.google.com/drive/folders/\(folderID)")
        flow.openSharingTapped()
        flow.cancelWaiting()
        XCTAssertFalse(flow.isWaiting)
        XCTAssertNil(flow.pollTargetID)

        let action = flow.apply(
            probe: .readable(bindID: folder, name: "Client Photos 2026")
        )
        XCTAssertEqual(action, .idle)
        XCTAssertEqual(flow.phase, .cancelled(folder))
    }

    func testNotAFolderStopsWaitingAndDoesNotBind() {
        var flow = ShareOnboarding()
        flow.setLink("https://drive.google.com/open?id=\(folderID)")
        flow.copyTapped()
        let action = flow.apply(probe: .notAFolder)
        XCTAssertEqual(action, .showNotAFolder)
        XCTAssertEqual(flow.rejection, .notAFolder)
        XCTAssertEqual(flow.phase, .failed(folder))
        XCTAssertFalse(flow.isWaiting)
    }

    func testFileLinkDoesNotPoll() {
        var flow = ShareOnboarding()
        flow.copyTapped()
        flow.setLink("https://drive.google.com/file/d/\(folderID)/view")
        XCTAssertEqual(flow.status, .fileLink)
        XCTAssertFalse(flow.isWaiting)
        XCTAssertNil(flow.pollTargetID)
    }

    func testBrowseRootIsSharedWithDriveflow() {
        XCTAssertEqual(BoundFolderBrowse.rootTitle, "Shared with Driveflow")
    }

    func testMintRequestSendsIDTokenAsBearerAndBody() throws {
        let idToken = "header.payload.sig"
        let request = ShareMintClient.mintRequest(
            url: URL(string: "https://usedriveflow.app/api/drive/session")!,
            googleIDToken: idToken
        )
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://usedriveflow.app/api/drive/session")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(idToken)")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
        XCTAssertEqual(body?["idToken"] as? String, idToken)
        XCTAssertNil(body?["email"])
    }

    func testMintJSONPrefersExpiresAt() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let both = """
        {"shareEmail":"lic-test@driveflow-503421.iam.gserviceaccount.com","accessToken":"ya29.test-token","expiresIn":120,"expiresAt":1700003600}
        """.data(using: .utf8)!
        let session = try ShareMintClient.session(fromMintData: both, now: now)
        XCTAssertEqual(session.shareEmail, "lic-test@driveflow-503421.iam.gserviceaccount.com")
        XCTAssertEqual(session.accessToken, "ya29.test-token")
        XCTAssertEqual(session.expiresAt, Date(timeIntervalSince1970: 1_700_003_600))

        let expiresInOnly = """
        {"shareEmail":"lic-test@driveflow-503421.iam.gserviceaccount.com","accessToken":"ya29.test-token","expiresIn":120}
        """.data(using: .utf8)!
        let fallback = try ShareMintClient.session(fromMintData: expiresInOnly, now: now)
        XCTAssertEqual(fallback.expiresAt, now.addingTimeInterval(120))

        let missingExpiry = """
        {"shareEmail":"lic-test@driveflow-503421.iam.gserviceaccount.com","accessToken":"ya29.test-token"}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try ShareMintClient.session(fromMintData: missingExpiry, now: now))
    }

    func testMintHTTPOutcomes() {
        XCTAssertEqual(ShareMintClient.httpOutcome(for: 200), .success)
        XCTAssertEqual(ShareMintClient.httpOutcome(for: 401), .reauthenticate)
        XCTAssertEqual(ShareMintClient.httpOutcome(for: 402), .unpaid)
        XCTAssertEqual(ShareMintClient.httpOutcome(for: 429), .retry)
        XCTAssertEqual(ShareMintClient.httpOutcome(for: 500), .mintFailed)
        XCTAssertEqual(ShareMintClient.httpOutcome(for: 503), .other)
        XCTAssertTrue(AppError.shareMintUnauthorized.requiresSignInAgain)
        XCTAssertTrue(AppError.licenseRequired(email: nil).requiresSignInAgain)
        XCTAssertFalse(AppError.shareMintFailed.requiresSignInAgain)
        XCTAssertFalse(AppError.shareMintRateLimited.requiresSignInAgain)
        let unpaid = DriveAccessSession.surfacing(.licenseRequired(email: nil), buyerEmail: "aaron@studiohalden.com")
        XCTAssertEqual(unpaid.localizedDescription.contains("aaron@studiohalden.com"), true)
    }

    func testMintRetryBackoffAndReleaseURL() {
        XCTAssertEqual(ShareMintClient.retryDelaySeconds(attempt: 0, retryAfterHeader: nil), 1)
        XCTAssertEqual(ShareMintClient.retryDelaySeconds(attempt: 1, retryAfterHeader: nil), 2)
        XCTAssertEqual(ShareMintClient.retryDelaySeconds(attempt: 2, retryAfterHeader: nil), 4)
        XCTAssertEqual(ShareMintClient.retryDelaySeconds(attempt: 0, retryAfterHeader: "9"), 9)
        XCTAssertEqual(ShareMintClient.retryDelaySeconds(attempt: 0, retryAfterHeader: "120"), 30)

        XCTAssertEqual(
            AppConfig.resolvedShareMintURL(environmentOverride: nil, isReleaseBuild: true)?.absoluteString,
            "https://usedriveflow.app/api/drive/session"
        )
        XCTAssertEqual(
            AppConfig.resolvedShareMintURL(
                environmentOverride: "https://staging.example/api/drive/session",
                isReleaseBuild: true
            )?.absoluteString,
            "https://staging.example/api/drive/session"
        )
        XCTAssertNil(AppConfig.resolvedShareMintURL(environmentOverride: nil, isReleaseBuild: false))
        XCTAssertNil(AppConfig.resolvedShareMintURL(environmentOverride: "  ", isReleaseBuild: false))
    }

    func testIDTokenExpiryReadsExpClaim() {
        let token = "eyJhbGciOiJub25lIiwidHlwIjoiSldUIn0.eyJleHAiOjE4OTM0NTYwMDAsImVtYWlsIjoiYWFyb25Ac3R1ZGlvaGFsZGVuLmNvbSJ9.sig"
        XCTAssertEqual(
            GoogleIDToken.expiresAt(token),
            Date(timeIntervalSince1970: 1_893_456_000)
        )
        XCTAssertTrue(
            GoogleIDToken.isFresh(token, now: Date(timeIntervalSince1970: 1_700_000_000))
        )
        XCTAssertFalse(
            GoogleIDToken.isFresh(token, now: Date(timeIntervalSince1970: 1_893_456_000))
        )
        XCTAssertNil(GoogleIDToken.expiresAt("not-a-jwt"))
    }

    func testLicenseJSONParsesShareSession() {
        let json: [String: Any] = [
            "allowed": true,
            "shareEmail": "lic-test@driveflow-503421.iam.gserviceaccount.com",
            "accessToken": "ya29.test-token",
            "expiresIn": 1800,
        ]
        let session = ShareMintClient.session(fromLicenseJSON: json)
        XCTAssertEqual(session?.shareEmail, "lic-test@driveflow-503421.iam.gserviceaccount.com")
        XCTAssertEqual(session?.accessToken, "ya29.test-token")
        XCTAssertNotNil(session?.expiresAt)
    }

    func testLicenseJSONIgnoresMissingToken() {
        let json: [String: Any] = [
            "allowed": true,
            "shareEmail": "lic-test@driveflow-503421.iam.gserviceaccount.com",
        ]
        XCTAssertNil(ShareMintClient.session(fromLicenseJSON: json))
    }

    func testBoundFolderStoreRoundTrip() throws {
        let email = "share-access-test-\(UUID().uuidString)@example.com"
        defer { BoundFolderStore.clear(buyerEmail: email) }

        XCTAssertTrue(BoundFolderStore.load(buyerEmail: email).isEmpty)
        BoundFolderStore.save(
            [
                BoundFolderRecord(id: folder, name: nil),
                BoundFolderRecord(id: shortcutTarget, name: nil),
            ],
            buyerEmail: email
        )
        XCTAssertEqual(BoundFolderStore.load(buyerEmail: email), Set([folder, shortcutTarget]))
    }

    func testBoundFolderStoreKeepsNameOrderAndLegacyIDs() throws {
        let email = "share-access-order-\(UUID().uuidString)@example.com"
        defer { BoundFolderStore.clear(buyerEmail: email) }

        BoundFolderStore.save(
            [
                BoundFolderRecord(id: folder, name: "Client Photos 2026"),
                BoundFolderRecord(id: shortcutTarget, name: "Wedding RAW"),
            ],
            buyerEmail: email
        )
        let loaded = BoundFolderStore.loadOrdered(buyerEmail: email)
        XCTAssertEqual(loaded.map(\.id), [folder, shortcutTarget])
        XCTAssertEqual(loaded.map(\.name), ["Client Photos 2026", "Wedding RAW"])

        let legacy = """
        ["legacy-folder-id-0001","legacy-folder-id-0002"]
        """.data(using: .utf8)!
        let decoded = BoundFolderStore.decode(legacy)
        XCTAssertEqual(
            decoded.map(\.id.raw),
            ["legacy-folder-id-0001", "legacy-folder-id-0002"]
        )
        XCTAssertEqual(decoded.map(\.name), [nil, nil])
    }
}
