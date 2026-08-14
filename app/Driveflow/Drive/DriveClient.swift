import Foundation

actor DriveClient {
    private let auth: AuthSession
    private let session: URLSession
    private var folderCache: [String: [DriveItem]] = [:]

    init(auth: AuthSession, session: URLSession = .shared) {
        self.auth = auth
        self.session = session
    }

    func invalidateCache() {
        folderCache.removeAll()
    }

    func list(parentID: String?, root: DriveRoot, pageToken: String? = nil) async throws -> (items: [DriveItem], nextPageToken: String?) {
        let cacheKey = "\(root.rawValue):\(parentID ?? "root"):\(pageToken ?? "")"
        if pageToken == nil, let cached = folderCache[cacheKey] {
            return (cached, nil)
        }

        var query: String
        switch root {
        case .myDrive:
            let parent = parentID ?? "root"
            query = "'\(parent)' in parents and trashed = false"
        case .sharedWithMe:
            if let parentID {
                query = "'\(parentID)' in parents and trashed = false"
            } else {
                query = "sharedWithMe = true and trashed = false"
            }
        case .sharedDrives:
            // Shared drives listing uses a different endpoint when parent is nil.
            if parentID == nil {
                return try await listSharedDrives()
            }
            query = "'\(parentID!)' in parents and trashed = false"
        }

        var components = URLComponents(url: AppConfig.driveAPIBase.appendingPathComponent("files"), resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "pageSize", value: "100"),
            URLQueryItem(name: "fields", value: "nextPageToken,files(id,name,mimeType,size,modifiedTime,md5Checksum,shortcutDetails(targetId,targetMimeType))"),
            URLQueryItem(name: "orderBy", value: "folder,name_natural"),
            URLQueryItem(name: "supportsAllDrives", value: "true"),
            URLQueryItem(name: "includeItemsFromAllDrives", value: "true"),
        ]
        if let pageToken {
            items.append(URLQueryItem(name: "pageToken", value: pageToken))
        }
        components.queryItems = items

        let json = try await getJSON(url: components.url!)
        let files = (json["files"] as? [[String: Any]] ?? []).compactMap(Self.parseItem)
        let next = json["nextPageToken"] as? String
        if pageToken == nil {
            folderCache[cacheKey] = files
        }
        return (files, next)
    }

    /// Resolves whether a Drive ID is a folder (follows shortcuts).
    func isFolder(id: String) async throws -> Bool {
        var components = URLComponents(
            url: AppConfig.driveAPIBase.appendingPathComponent("files/\(id)"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(
                name: "fields",
                value: "mimeType,shortcutDetails(targetId,targetMimeType)"
            ),
            URLQueryItem(name: "supportsAllDrives", value: "true"),
        ]
        let json = try await getJSON(url: components.url!)
        let mime = json["mimeType"] as? String ?? ""
        if mime == "application/vnd.google-apps.folder" { return true }
        let targetMime = (json["shortcutDetails"] as? [String: Any])?["targetMimeType"] as? String
        return targetMime == "application/vnd.google-apps.folder"
    }

    func search(query: String) async throws -> [DriveItem] {
        let escaped = query.replacingOccurrences(of: "'", with: "\\'")
        var components = URLComponents(url: AppConfig.driveAPIBase.appendingPathComponent("files"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "q", value: "name contains '\(escaped)' and trashed = false"),
            URLQueryItem(name: "pageSize", value: "50"),
            URLQueryItem(name: "fields", value: "files(id,name,mimeType,size,modifiedTime,md5Checksum,shortcutDetails(targetId,targetMimeType))"),
            URLQueryItem(name: "supportsAllDrives", value: "true"),
            URLQueryItem(name: "includeItemsFromAllDrives", value: "true"),
        ]
        let json = try await getJSON(url: components.url!)
        return (json["files"] as? [[String: Any]] ?? []).compactMap(Self.parseItem)
    }

    private func listSharedDrives() async throws -> (items: [DriveItem], nextPageToken: String?) {
        var components = URLComponents(url: AppConfig.driveAPIBase.appendingPathComponent("drives"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "pageSize", value: "50"),
            URLQueryItem(name: "fields", value: "nextPageToken,drives(id,name)"),
        ]
        let json = try await getJSON(url: components.url!)
        let drives = (json["drives"] as? [[String: Any]] ?? []).map { dict in
            DriveItem(
                id: dict["id"] as? String ?? UUID().uuidString,
                name: dict["name"] as? String ?? "Shared drive",
                mimeType: "application/vnd.google-apps.folder",
                size: nil,
                modifiedTime: nil,
                md5Checksum: nil,
                shortcutTargetId: nil,
                shortcutTargetMimeType: nil,
                isFolder: true,
                isGoogleNative: false,
                isSharedDriveRoot: true
            )
        }
        return (drives, json["nextPageToken"] as? String)
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
            throw AppError.driveAPI(body)
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
