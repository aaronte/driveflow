import Foundation

enum JobStatus: String, Codable, Sendable {
    case queued
    case running
    case paused
    case completed
    case failed
    case cancelled
}

struct QueuedItem: Codable, Equatable, Sendable {
    var id: String
    var name: String
    var isFolder: Bool
    var isSharedDriveRoot: Bool
    var mimeType: String?
}

struct DownloadJob: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var createdAt: Date
    var updatedAt: Date
    var items: [QueuedItem]
    var destinationPath: String
    var status: JobStatus
    /// rclone async job ids for the current engine process (empty when idle).
    var rcloneJobIDs: [String]
    var errorMessage: String?
    var bytesTransferred: Int64
    var totalBytes: Int64

    init(items: [DriveItem], destination: URL) {
        id = UUID()
        createdAt = Date()
        updatedAt = Date()
        self.items = items.map {
            QueuedItem(
                id: $0.downloadID,
                name: $0.name,
                isFolder: $0.downloadIsFolder,
                isSharedDriveRoot: $0.isSharedDriveRoot,
                mimeType: $0.mimeType
            )
        }
        destinationPath = destination.path
        status = .queued
        rcloneJobIDs = []
        bytesTransferred = 0
        totalBytes = items.compactMap(\.size).reduce(0, +)
    }

    var title: String {
        if items.count == 1 { return items[0].name }
        return "\(items.count) items"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        destinationPath = try container.decode(String.self, forKey: .destinationPath)
        status = try container.decode(JobStatus.self, forKey: .status)
        errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
        bytesTransferred = try container.decode(Int64.self, forKey: .bytesTransferred)
        totalBytes = try container.decode(Int64.self, forKey: .totalBytes)

        if let ids = try container.decodeIfPresent([String].self, forKey: .rcloneJobIDs), !ids.isEmpty {
            rcloneJobIDs = ids
        } else if let legacy = try container.decodeIfPresent(String.self, forKey: .rcloneJobID) {
            rcloneJobIDs = [legacy]
        } else {
            rcloneJobIDs = []
        }

        if let modern = try container.decodeIfPresent([QueuedItem].self, forKey: .items), !modern.isEmpty {
            items = modern
            return
        }

        // Legacy jobs.json used parallel arrays for queued entries.
        let ids = try container.decode([String].self, forKey: .itemIDs)
        let names = try container.decode([String].self, forKey: .itemNames)
        let folders = try container.decodeIfPresent([Bool].self, forKey: .itemIsFolders) ?? []
        let sharedRoots = try container.decodeIfPresent([Bool].self, forKey: .itemIsSharedDriveRoots) ?? []
        let mimeTypes = try container.decodeIfPresent([String].self, forKey: .itemMimeTypes) ?? []
        items = ids.enumerated().map { index, itemID in
            QueuedItem(
                id: itemID,
                name: index < names.count ? names[index] : itemID,
                isFolder: index < folders.count ? folders[index] : false,
                isSharedDriveRoot: index < sharedRoots.count ? sharedRoots[index] : false,
                mimeType: index < mimeTypes.count ? mimeTypes[index] : nil
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(items, forKey: .items)
        try container.encode(destinationPath, forKey: .destinationPath)
        try container.encode(status, forKey: .status)
        try container.encode(rcloneJobIDs, forKey: .rcloneJobIDs)
        try container.encodeIfPresent(errorMessage, forKey: .errorMessage)
        try container.encode(bytesTransferred, forKey: .bytesTransferred)
        try container.encode(totalBytes, forKey: .totalBytes)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case createdAt
        case updatedAt
        case items
        case destinationPath
        case status
        case rcloneJobID // legacy singular (decode only)
        case rcloneJobIDs
        case errorMessage
        case bytesTransferred
        case totalBytes
        // Legacy parallel-array keys (decode only).
        case itemIDs
        case itemNames
        case itemIsFolders
        case itemIsSharedDriveRoots
        case itemMimeTypes
    }
}
