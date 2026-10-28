import Foundation

struct FolderID: Hashable, Sendable, Codable, Equatable {
    let raw: String

    init?(_ raw: String) {
        guard Self.isValid(raw) else { return nil }
        self.raw = raw
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let id = FolderID(raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid Drive folder id"
            )
        }
        self = id
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }

    private static let characters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
    )

    private static func isValid(_ raw: String) -> Bool {
        guard (10...128).contains(raw.count) else { return false }
        return raw.unicodeScalars.allSatisfy { characters.contains($0) }
    }
}

/// A recognized link is only an ID. The folder name needs service-account access.
enum DriveFolderLink {
    enum Status: Equatable {
        case empty
        case recognized(folderID: FolderID)
        case fileLink
        case unrecognized
    }

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

    static func interpret(_ raw: String) -> Status {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .empty }
        if let folderID = FolderID(trimmed) { return .recognized(folderID: folderID) }

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
           let folderID = FolderID(id) {
            return .recognized(folderID: folderID)
        }
        return .unrecognized
    }

    static func sharingURL(folderID: FolderID) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "drive.google.com"
        components.path = "/drive/folders/\(folderID.raw)"
        guard let url = components.url else {
            preconditionFailure("FolderID characters are URL-safe")
        }
        return url
    }

    private static func folderID(inPath path: String) -> FolderID? {
        let parts = path.split(separator: "/").map(String.init)
        guard let index = parts.lastIndex(of: "folders"),
              parts.indices.contains(index + 1)
        else {
            return nil
        }
        return FolderID(parts[index + 1])
    }
}
