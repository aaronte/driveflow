import Foundation

/// Parses a Google Drive folder link the buyer pasted.
///
/// The app cannot read the folder name until the service account has access,
/// so a recognized link is only an ID — not a title.
enum DriveFolderLink {
    enum Status: Equatable {
        case empty
        case recognized(folderID: String)
        case fileLink
        case unrecognized
    }

    private static let folderIDCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
    )
    private static let filePathMarkers = [
        "/file/d/",
        "/document/d/",
        "/spreadsheets/d/",
        "/presentation/d/",
        "/forms/d/",
        "/drawings/d/",
    ]
    /// `open` / folderview links identify a file or a folder; files.get decides.
    private static let idQueryPaths: Set<String> = [
        "/open",
        "/folderview",
        "/embeddedfolderview",
    ]

    static func isFolderID(_ raw: String) -> Bool {
        guard (10...128).contains(raw.count) else { return false }
        return raw.unicodeScalars.allSatisfy { folderIDCharacters.contains($0) }
    }

    static func interpret(_ raw: String) -> Status {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .empty }
        if isFolderID(trimmed) { return .recognized(folderID: trimmed) }

        var candidate = trimmed
        if !candidate.contains("://"),
           candidate.lowercased().contains("drive.google.com") {
            candidate = "https://\(candidate)"
        }
        guard let components = URLComponents(string: candidate),
              let host = components.host?.lowercased()
        else {
            return .unrecognized
        }

        let path = components.path
        if filePathMarkers.contains(where: { path.contains($0) }) {
            return .fileLink
        }
        guard host == "drive.google.com" else {
            return .unrecognized
        }
        if let folderID = folderID(inPath: path) {
            return .recognized(folderID: folderID)
        }
        if idQueryPaths.contains(path),
           let id = components.queryItems?.first(where: { $0.name == "id" })?.value,
           isFolderID(id) {
            return .recognized(folderID: id)
        }
        return .unrecognized
    }

    /// Folder the buyer should open to share with the service account.
    static func sharingURL(folderID: String) -> URL? {
        guard isFolderID(folderID) else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "drive.google.com"
        components.path = "/drive/folders/\(folderID)"
        return components.url
    }

    private static func folderID(inPath path: String) -> String? {
        let parts = path.split(separator: "/").map(String.init)
        guard let index = parts.lastIndex(of: "folders"),
              parts.indices.contains(index + 1)
        else {
            return nil
        }
        let id = parts[index + 1]
        return isFolderID(id) ? id : nil
    }
}
