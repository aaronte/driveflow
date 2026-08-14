import Foundation

struct DriveItem: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let mimeType: String
    let size: Int64?
    let modifiedTime: Date?
    let md5Checksum: String?
    let shortcutTargetId: String?
    let shortcutTargetMimeType: String?
    let isFolder: Bool
    let isGoogleNative: Bool
    /// True for shared-drive roots from `drives.list` (ID is a team drive, not a folder).
    let isSharedDriveRoot: Bool

    /// ID rclone should fetch (shortcut target when present).
    var downloadID: String { shortcutTargetId ?? id }

    /// Whether the download target is a folder (including shortcuts to folders).
    var downloadIsFolder: Bool {
        if isFolder { return true }
        return shortcutTargetMimeType == "application/vnd.google-apps.folder"
    }

    /// Extension rclone appends when exporting a Google-native file.
    var exportFileExtension: String? {
        Self.exportFileExtension(forMimeType: mimeType)
    }

    var displaySize: String {
        if downloadIsFolder { return "Folder" }
        if isGoogleNative { return "Google Doc" }
        guard let size else { return "—" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    static func exportFileExtension(forMimeType mimeType: String) -> String? {
        switch mimeType {
        case "application/vnd.google-apps.document":
            return "docx"
        case "application/vnd.google-apps.spreadsheet":
            return "xlsx"
        case "application/vnd.google-apps.presentation":
            return "pptx"
        case let mime
            where mime.hasPrefix("application/vnd.google-apps.")
                && mime != "application/vnd.google-apps.folder"
                && mime != "application/vnd.google-apps.shortcut":
            return "pdf"
        default:
            return nil
        }
    }
}

struct DriveBreadcrumb: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
}

enum DriveRoot: String, CaseIterable, Identifiable {
    case myDrive
    case sharedWithMe
    case sharedDrives

    var id: String { rawValue }

    var title: String {
        switch self {
        case .myDrive: return "My Drive"
        case .sharedWithMe: return "Shared with me"
        case .sharedDrives: return "Shared drives"
        }
    }
}
