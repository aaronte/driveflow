import Foundation

struct BoundFolderRecord: Codable, Equatable, Sendable {
    var id: FolderID
    var name: String?
}

/// Per buyer, so a shared service account cannot list another buyer's folders.
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
        let normalized = email
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Percent-encoding is injective. Replacing "@" with "_at_" collides
        // `a@b_at_c.com` with `a_at_b@c.com` and mixes two buyers' folders.
        let encoded = normalized.addingPercentEncoding(
            withAllowedCharacters: .alphanumerics
        ) ?? "unknown"
        return directory.appendingPathComponent("bound-folders-\(encoded).json")
    }

    static func load(buyerEmail: String) -> Set<FolderID> {
        Set(loadOrdered(buyerEmail: buyerEmail).map(\.id))
    }

    static func loadOrdered(buyerEmail: String) -> [BoundFolderRecord] {
        let url = fileURL(forBuyerEmail: buyerEmail)
        guard let data = try? Data(contentsOf: url) else { return [] }
        return decode(data)
    }

    static func bind(_ record: BoundFolderRecord, buyerEmail: String) {
        var records = loadOrdered(buyerEmail: buyerEmail)
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            let trimmed = record.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let trimmed, !trimmed.isEmpty, records[index].name != trimmed else { return }
            records[index].name = trimmed
        } else {
            let trimmed = record.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = (trimmed?.isEmpty == false) ? trimmed : nil
            records.append(BoundFolderRecord(id: record.id, name: name))
        }
        save(records, buyerEmail: buyerEmail)
    }

    static func updateName(id: FolderID, name: String, buyerEmail: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var records = loadOrdered(buyerEmail: buyerEmail)
        guard let index = records.firstIndex(where: { $0.id == id }), records[index].name != trimmed else {
            return
        }
        records[index].name = trimmed
        save(records, buyerEmail: buyerEmail)
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

    static func decode(_ data: Data) -> [BoundFolderRecord] {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        if let records = json as? [[String: Any]] {
            return records.compactMap { dict in
                guard let raw = dict["id"] as? String, let id = FolderID(raw) else { return nil }
                return BoundFolderRecord(id: id, name: dict["name"] as? String)
            }
        }
        return []
    }

    static func clear(buyerEmail: String) {
        try? FileManager.default.removeItem(at: fileURL(forBuyerEmail: buyerEmail))
    }
}
