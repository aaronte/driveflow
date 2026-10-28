import Foundation

enum FolderProbe: Equatable {
    case notReadableYet
    case notAFolder
    case unauthorized
    /// `bindID` may be the shortcut target rather than the pasted folder.
    case readable(bindID: String, name: String)
}

enum ShareBindAction: Equatable {
    case idle
    case pollAgain
    case refreshToken
    case bind(folderID: String)
    case showNotAFolder
}

enum ShareLinkRejection: Equatable {
    case notAFolder
}

struct ShareOnboarding: Equatable {
    private(set) var linkText = ""
    private(set) var status: DriveFolderLink.Status = .empty
    private(set) var didCopy = false
    private(set) var didOpenSharing = false
    private(set) var isWaiting = false
    private(set) var boundIDs: Set<String> = []
    private(set) var boundNames: [String: String] = [:]
    private(set) var rejection: ShareLinkRejection?

    var recognizedFolderID: String? {
        if case .recognized(let folderID) = status { return folderID }
        return nil
    }

    var pollTargetID: String? {
        guard isWaiting else { return nil }
        return recognizedFolderID
    }

    mutating func setLink(_ raw: String) {
        linkText = raw
        status = DriveFolderLink.interpret(raw)
        rejection = nil
        guard recognizedFolderID != nil else {
            isWaiting = false
            return
        }
        if didCopy || didOpenSharing {
            isWaiting = true
        }
    }

    mutating func copyTapped() {
        didCopy = true
        if recognizedFolderID != nil {
            isWaiting = true
        }
    }

    mutating func openSharingTapped() {
        didOpenSharing = true
        if recognizedFolderID != nil {
            isWaiting = true
        }
    }

    mutating func cancelWaiting() {
        isWaiting = false
    }

    mutating func resetForNewFolder() {
        linkText = ""
        status = .empty
        didCopy = false
        didOpenSharing = false
        isWaiting = false
        rejection = nil
    }

    mutating func apply(probe: FolderProbe) -> ShareBindAction {
        guard isWaiting, recognizedFolderID != nil else { return .idle }
        switch probe {
        case .notReadableYet:
            return .pollAgain
        case .unauthorized:
            return .refreshToken
        case .notAFolder:
            isWaiting = false
            rejection = .notAFolder
            return .showNotAFolder
        case .readable(let bindID, let name):
            guard DriveFolderLink.isFolderID(bindID) else {
                isWaiting = false
                rejection = .notAFolder
                return .showNotAFolder
            }
            boundIDs.insert(bindID)
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                boundNames[bindID] = trimmed
            }
            isWaiting = false
            return .bind(folderID: bindID)
        }
    }
}

enum DriveFolderAccess {
    private static let folderMIME = "application/vnd.google-apps.folder"

    static func interpret(
        statusCode: Int,
        body: [String: Any]?,
        pastedID: String
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

    private static func interpretSuccess(_ body: [String: Any], pastedID: String) -> FolderProbe {
        let mime = body["mimeType"] as? String ?? ""
        let name = (body["name"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if mime == folderMIME {
            guard DriveFolderLink.isFolderID(pastedID) else { return .notAFolder }
            return .readable(bindID: pastedID, name: name)
        }
        let shortcut = body["shortcutDetails"] as? [String: Any]
        let targetMIME = shortcut?["targetMimeType"] as? String
        let targetID = shortcut?["targetId"] as? String
        if targetMIME == folderMIME, let targetID, DriveFolderLink.isFolderID(targetID) {
            return .readable(bindID: targetID, name: name)
        }
        return .notAFolder
    }
}
