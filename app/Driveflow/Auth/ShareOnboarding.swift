import Foundation

enum FolderProbe: Equatable {
    case notReadableYet
    case notAFolder
    case unauthorized
    /// `bindID` may be the shortcut target rather than the pasted folder.
    case readable(bindID: FolderID, name: String)
}

enum ShareBindAction: Equatable {
    case idle
    case pollAgain
    case refreshToken
    case bind(folderID: FolderID, name: String)
    case showNotAFolder
}

enum ShareLinkRejection: Equatable {
    case notAFolder
}

/// One files.get 401 refreshes the service-account token. Further 401s in that
/// streak wait, so a dead token cannot mint in a loop. A later 404 clears it.
struct UnauthorizedRetry: Equatable {
    private(set) var refreshedDuringStreak = false

    var shouldRefresh: Bool { !refreshedDuringStreak }

    mutating func markRefreshed() {
        refreshedDuringStreak = true
    }

    mutating func clear() {
        refreshedDuringStreak = false
    }
}

struct ShareOnboarding: Equatable {
    private(set) var linkText = ""
    private(set) var status: DriveFolderLink.Status = .empty
    private(set) var didCopy = false
    private(set) var shareArmed = false
    private(set) var phase: Phase = .idle

    enum Phase: Equatable {
        case idle
        case linkParsed(FolderID)
        case waiting(FolderID)
        case failed(FolderID)
        case cancelled(FolderID)
        case bound(FolderID)
    }

    var isWaiting: Bool {
        if case .waiting = phase { return true }
        return false
    }

    var rejection: ShareLinkRejection? {
        if case .failed = phase { return .notAFolder }
        return nil
    }

    var recognizedFolderID: FolderID? {
        if case .recognized(let folderID) = status { return folderID }
        return nil
    }

    var pollTargetID: FolderID? {
        if case .waiting(let folderID) = phase { return folderID }
        return nil
    }

    mutating func setLink(_ raw: String) {
        linkText = raw
        status = DriveFolderLink.interpret(raw)
        switch status {
        case .recognized(let folderID):
            phase = shareArmed ? .waiting(folderID) : .linkParsed(folderID)
        case .empty, .fileLink, .unrecognized:
            phase = .idle
        }
    }

    mutating func copyTapped() {
        didCopy = true
        shareArmed = true
        if case .recognized(let folderID) = status {
            phase = .waiting(folderID)
        }
    }

    mutating func openSharingTapped() {
        shareArmed = true
        if case .recognized(let folderID) = status {
            phase = .waiting(folderID)
        }
    }

    mutating func cancelWaiting() {
        if case .waiting(let folderID) = phase {
            phase = .cancelled(folderID)
        }
    }

    mutating func resetForNewFolder() {
        self = ShareOnboarding()
    }

    mutating func apply(probe: FolderProbe) -> ShareBindAction {
        guard case .waiting(let pastedID) = phase else { return .idle }
        switch probe {
        case .notReadableYet:
            return .pollAgain
        case .unauthorized:
            return .refreshToken
        case .notAFolder:
            phase = .failed(pastedID)
            return .showNotAFolder
        case .readable(let bindID, let name):
            phase = .bound(bindID)
            return .bind(folderID: bindID, name: name)
        }
    }
}

enum DriveFolderAccess {
    private static let folderMIME = "application/vnd.google-apps.folder"

    static func interpret(
        statusCode: Int,
        body: [String: Any]?,
        pastedID: FolderID
    ) -> FolderProbe {
        switch statusCode {
        case 401:
            return .unauthorized
        case 403, 404:
            return .notReadableYet
        case 200..<300:
            guard let body else { return .notReadableYet }
            return interpretSuccess(body, pastedID: pastedID)
        default:
            return .notReadableYet
        }
    }

    private static func interpretSuccess(_ body: [String: Any], pastedID: FolderID) -> FolderProbe {
        let mime = body["mimeType"] as? String ?? ""
        let name = (body["name"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if mime == folderMIME {
            return .readable(bindID: pastedID, name: name)
        }
        let shortcut = body["shortcutDetails"] as? [String: Any]
        let targetMIME = shortcut?["targetMimeType"] as? String
        let targetID = shortcut?["targetId"] as? String
        if targetMIME == folderMIME, let targetID, let folderID = FolderID(targetID) {
            return .readable(bindID: folderID, name: name)
        }
        return .notAFolder
    }
}
