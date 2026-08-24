import Foundation

/// Persists Drive folder/file IDs bound to a purchaser email.
///
/// Used when a single service account is shared across licenses so tenant A
/// never sees tenant B’s shares in the Shared-with-me root.
enum BoundFolderStore {
    private static var directory: URL {
        let directory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("Driveflow", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func fileURL(forBuyerEmail email: String) -> URL {
        let safe = email
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "@", with: "_at_")
            .replacingOccurrences(of: "/", with: "_")
        return directory.appendingPathComponent("bound-folders-\(safe).json")
    }

    static func load(buyerEmail: String) -> Set<String> {
        let url = fileURL(forBuyerEmail: buyerEmail)
        guard let data = try? Data(contentsOf: url),
              let ids = try? JSONDecoder().decode([String].self, from: data)
        else {
            return []
        }
        return Set(ids)
    }

    static func save(_ ids: Set<String>, buyerEmail: String) {
        let url = fileURL(forBuyerEmail: buyerEmail)
        let sorted = ids.sorted()
        guard let data = try? JSONEncoder().encode(sorted) else { return }
        try? data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    static func clear(buyerEmail: String) {
        try? FileManager.default.removeItem(at: fileURL(forBuyerEmail: buyerEmail))
    }
}
