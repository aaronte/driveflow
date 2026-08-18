import Foundation

actor DriveClient {
    private let auth: AuthSession
    private let session: URLSession

    init(auth: AuthSession, session: URLSession = .shared) {
        self.auth = auth
        self.session = session
    }

    func invalidateCache() {
        // Kept for sign-out call sites; picker sessions do not cache Drive listings.
    }

    /// Metadata for files the user granted via Google’s desktop Picker.
    func files(ids: [String]) async throws -> [DriveItem] {
        var items: [DriveItem] = []
        items.reserveCapacity(ids.count)
        for id in ids {
            items.append(try await file(id: id))
        }
        return items
    }

    func file(id: String) async throws -> DriveItem {
        var components = URLComponents(
            url: AppConfig.driveAPIBase.appendingPathComponent("files/\(id)"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(
                name: "fields",
                value: "id,name,mimeType,size,modifiedTime,md5Checksum,shortcutDetails(targetId,targetMimeType)"
            ),
            URLQueryItem(name: "supportsAllDrives", value: "true"),
        ]
        let json = try await getJSON(url: components.url!)
        guard let item = Self.parseItem(json) else {
            throw AppError.driveAPI("Couldn’t read metadata for file \(id).")
        }
        return item
    }

    /// Resolves whether a Drive ID is a folder (follows shortcuts).
    func isFolder(id: String) async throws -> Bool {
        let item = try await file(id: id)
        return item.downloadIsFolder
    }

    /// `drive.file` often grants the folder node but not its children.
    /// Probe listing; on denied/empty access surface a clear “pick files inside” error.
    func assertFolderChildrenAccessible(id: String) async throws {
        var components = URLComponents(
            url: AppConfig.driveAPIBase.appendingPathComponent("files"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "q", value: "'\(id)' in parents and trashed = false"),
            URLQueryItem(name: "pageSize", value: "10"),
            URLQueryItem(name: "fields", value: "files(id)"),
            URLQueryItem(name: "supportsAllDrives", value: "true"),
            URLQueryItem(name: "includeItemsFromAllDrives", value: "true"),
        ]
        do {
            let json = try await getJSON(url: components.url!)
            let files = json["files"] as? [[String: Any]] ?? []
            // Empty listings under drive.file usually mean children were not granted
            // (or the folder is empty). Either way, folder sync is not useful — ask
            // the user to pick files inside.
            if files.isEmpty {
                throw AppError.folderPickRequiresFiles
            }
        } catch let error as AppError {
            if case .folderPickRequiresFiles = error {
                throw error
            }
            if case .driveAPI(let detail) = error {
                let lower = detail.lowercased()
                if lower.contains("403")
                    || lower.contains("404")
                    || lower.contains("notfound")
                    || lower.contains("forbidden")
                    || lower.contains("insufficientpermissions")
                    || lower.contains("insufficient file permissions") {
                    throw AppError.folderPickRequiresFiles
                }
            }
            throw error
        }
    }

    private func getJSON(url: URL) async throws -> [String: Any] {
        let token = try await auth.validAccessToken()
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AppError.network("No response from Drive.")
        }
        if http.statusCode == 401 {
            throw AppError.tokenExpired
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            // Embed status so callers can distinguish 403/404 without parsing JSON only.
            throw AppError.driveAPI("HTTP \(http.statusCode) \(body)")
        }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private static let googleNativePrefixes = [
        "application/vnd.google-apps.document",
        "application/vnd.google-apps.spreadsheet",
        "application/vnd.google-apps.presentation",
        "application/vnd.google-apps.drawing",
        "application/vnd.google-apps.form",
    ]

    private static func parseItem(_ dict: [String: Any]) -> DriveItem? {
        guard let id = dict["id"] as? String, let name = dict["name"] as? String else { return nil }
        let mime = dict["mimeType"] as? String ?? "application/octet-stream"
        let shortcutDetails = dict["shortcutDetails"] as? [String: Any]
        let shortcutTargetId = shortcutDetails?["targetId"] as? String
        let shortcutTargetMimeType = shortcutDetails?["targetMimeType"] as? String
        let isFolder = mime == "application/vnd.google-apps.folder"
            || shortcutTargetMimeType == "application/vnd.google-apps.folder"
        let size = (dict["size"] as? String).flatMap(Int64.init)
        let modified: Date? = {
            guard let raw = dict["modifiedTime"] as? String else { return nil }
            return ISO8601DateFormatter().date(from: raw)
        }()
        let isNative = googleNativePrefixes.contains { mime.hasPrefix($0) }
        return DriveItem(
            id: id,
            name: name,
            mimeType: mime,
            size: size,
            modifiedTime: modified,
            md5Checksum: dict["md5Checksum"] as? String,
            shortcutTargetId: shortcutTargetId,
            shortcutTargetMimeType: shortcutTargetMimeType,
            isFolder: isFolder,
            isGoogleNative: isNative,
            isSharedDriveRoot: false
        )
    }
}
