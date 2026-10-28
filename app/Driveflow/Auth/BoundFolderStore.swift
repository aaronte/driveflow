import Foundation

/// One Drive folder the buyer pasted and that the service account can read.
struct BoundFolderRecord: Codable, Equatable, Sendable {
    var id: String
    var name: String?
}

/// Persists Drive folder IDs bound to a purchaser email, in insertion order.
///
/// Used when a single service account is shared across licenses so the browser
/// lists only folders this buyer added — not every folder shared with the SA.
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
        Set(loadOrdered(buyerEmail: buyerEmail).map(\.id))
    }

    static func loadOrdered(buyerEmail: String) -> [BoundFolderRecord] {
        let url = fileURL(forBuyerEmail: buyerEmail)
        guard let data = try? Data(contentsOf: url) else { return [] }
        return decode(data)
    }

    static func save(_ ids: Set<String>, buyerEmail: String) {
        let existing = loadOrdered(buyerEmail: buyerEmail)
        var ordered = existing.filter { ids.contains($0.id) }
        for id in ids.sorted() where !ordered.contains(where: { $0.id == id }) {
            ordered.append(BoundFolderRecord(id: id, name: nil))
        }
        save(ordered, buyerEmail: buyerEmail)
    }

    static func save(_ records: [BoundFolderRecord], buyerEmail: String) {
        let url = fileURL(forBuyerEmail: buyerEmail)
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    /// Accepts `[{id,name}]` and the older `[id]` array.
    static func decode(_ data: Data) -> [BoundFolderRecord] {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        if let ids = json as? [String] {
            return ids.filter { !$0.isEmpty }.map { BoundFolderRecord(id: $0, name: nil) }
        }
        if let records = json as? [[String: Any]] {
            return records.compactMap { dict in
                guard let id = dict["id"] as? String, !id.isEmpty else { return nil }
                return BoundFolderRecord(id: id, name: dict["name"] as? String)
            }
        }
        return []
    }

    static func clear(buyerEmail: String) {
        try? FileManager.default.removeItem(at: fileURL(forBuyerEmail: buyerEmail))
    }
}
