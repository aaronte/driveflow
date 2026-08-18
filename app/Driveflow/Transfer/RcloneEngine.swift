import Foundation
import Darwin
import Security

struct TransferStats: Equatable, Sendable {
    var bytes: Int64 = 0
    var totalBytes: Int64 = 0
    var speed: Double = 0
    var eta: Double?
    var transferring: [String] = []
    var errors: Int = 0
    var checks: Int = 0
    var transfers: Int = 0

    var fraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, Double(bytes) / Double(totalBytes))
    }

    var speedLabel: String {
        guard speed > 0 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .file) + "/s"
    }

    var etaLabel: String {
        guard let eta, eta.isFinite, eta > 0 else { return "—" }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter.string(from: eta) ?? "—"
    }
}

actor RcloneEngine {
    /// Isolated remote name — never touch the user's default rclone remotes.
    private static let remoteName = "driveflow"

    private var process: Process?
    /// Mirrored for synchronous terminate-on-quit (Process.terminate is thread-safe enough).
    nonisolated(unsafe) private var shutdownProcess: Process?
    private var logHandle: FileHandle?
    private var started = false
    private var lastTermination: String?
    private var rcPort: UInt16 = 0
    private var rcPass = ""
    private let rcUser = AppConfig.rcloneRCUser

    private var binaryURL: URL {
        Bundle.main.url(forResource: "rclone", withExtension: nil)
            ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/rclone")
    }

    private var supportDirectory: URL {
        let directory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("Driveflow", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    /// App-private rclone config — never `~/.config/rclone/rclone.conf`.
    private var configURL: URL {
        supportDirectory.appendingPathComponent("rclone.conf")
    }

    private var logURL: URL {
        supportDirectory.appendingPathComponent("rclone.log")
    }

    func ensureRunning() async throws {
        if started, let process, process.isRunning { return }
        guard FileManager.default.fileExists(atPath: binaryURL.path) else {
            throw AppError.rcloneMissing
        }

        let port = try Self.reserveEphemeralPort()
        let pass = Self.randomPassword()
        rcPort = port
        rcPass = pass

        let process = Process()
        process.executableURL = binaryURL
        // Keep RC credentials out of `ps` argv — rclone reads RCLONE_RC_*.
        var environment = ProcessInfo.processInfo.environment
        environment["RCLONE_RC_USER"] = rcUser
        environment["RCLONE_RC_PASS"] = pass
        environment["RCLONE_CONFIG"] = configURL.path
        process.environment = environment
        process.arguments = [
            "rcd",
            "--config=\(configURL.path)",
            "--rc-addr=127.0.0.1:\(port)",
            "--rc-web-gui=false",
            "--transfers=8",
            "--multi-thread-streams=8",
            "--drive-export-formats=docx,xlsx,pptx,pdf",
            "--log-level=INFO",
        ]

        FileManager.default.createFile(
            atPath: logURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        )
        Self.restrictToOwner(logURL)
        let logHandle = try FileHandle(forWritingTo: logURL)
        try logHandle.seekToEnd()
        process.standardOutput = logHandle
        process.standardError = logHandle
        process.terminationHandler = { [weak self] process in
            let reason = process.terminationReason == .uncaughtSignal ? "signal" : "exit"
            let detail = "\(reason) \(process.terminationStatus)"
            Task { await self?.markStopped(detail: detail) }
        }
        lastTermination = nil
        try process.run()
        self.process = process
        self.shutdownProcess = process
        self.logHandle = logHandle
        started = true

        for _ in 0..<20 {
            if await ping() { return }
            if !process.isRunning {
                let detail = lastTermination
                    ?? "exit \(process.terminationStatus)"
                throw AppError.rcloneFailed(
                    "Download engine stopped during startup (\(detail))."
                )
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw AppError.rcloneFailed("Engine started but didn’t become ready.")
    }

    private func markStopped(detail: String) {
        lastTermination = detail
        started = false
        process = nil
        shutdownProcess = nil
        try? logHandle?.close()
        logHandle = nil
    }

    func stop() {
        process?.terminate()
        process = nil
        shutdownProcess = nil
        started = false
        try? logHandle?.close()
        logHandle = nil
    }

    /// Synchronous path for app termination — safe to call without awaiting the actor.
    nonisolated func terminateProcessForShutdown() {
        shutdownProcess?.terminate()
    }

    func configureDrive(tokenJSON: String) async throws {
        try await ensureRunning()
        _ = try await rc("config/create", body: [
            "name": Self.remoteName,
            "type": "drive",
            "parameters": [
                "token": tokenJSON,
                "scope": AppConfig.driveScope,
                "client_id": AppConfig.googleClientID,
                "client_secret": AppConfig.googleClientSecret,
            ],
            "opt": [
                "nonInteractive": true,
                "obscure": true,
            ],
        ])
        Self.restrictToOwner(configURL)
    }

    /// Remove the Drive remote, stop the engine, and delete the app-private config.
    func clearPersistedCredentials() async {
        if started {
            _ = try? await rc("config/delete", body: ["name": Self.remoteName])
            stop()
        }
        try? FileManager.default.removeItem(at: configURL)
    }

    /// Copy a Drive file or folder (by ID) into destination/<name>.
    func copyItem(
        id: String,
        name: String,
        isFolder: Bool,
        isSharedDriveRoot: Bool = false,
        mimeType: String? = nil,
        destination: URL
    ) async throws -> String {
        try await ensureRunning()
        let fileName = Self.destinationFileName(name: name, isFolder: isFolder, mimeType: mimeType)
        let dst = destination.appendingPathComponent(fileName)
        try FileManager.default.createDirectory(
            at: dst.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // If a prior failed file-copy left a directory at the destination, treat as folder.
        var treatAsFolder = isFolder || isSharedDriveRoot
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: dst.path, isDirectory: &isDirectory), isDirectory.boolValue {
            treatAsFolder = true
        }

        do {
            return try await startCopy(
                id: id,
                destination: dst,
                isFolder: treatAsFolder,
                isSharedDriveRoot: isSharedDriveRoot
            )
        } catch {
            // Misclassified folders often look like files in Drive listings / shortcuts.
            let message = (error as? AppError)?.localizedDescription ?? error.localizedDescription
            if !treatAsFolder, message.localizedCaseInsensitiveContains("is a directory") {
                return try await startCopy(
                    id: id,
                    destination: dst,
                    isFolder: true,
                    isSharedDriveRoot: false
                )
            }
            throw error
        }
    }

    private func startCopy(
        id: String,
        destination dst: URL,
        isFolder: Bool,
        isSharedDriveRoot: Bool
    ) async throws -> String {
        let response: [String: Any]
        if isFolder {
            try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)
            let srcFs = isSharedDriveRoot
                ? "\(Self.remoteName),team_drive=\(id):"
                : "\(Self.remoteName),root_folder_id=\(id):"
            response = try await rc("sync/copy", body: [
                "srcFs": srcFs,
                "dstFs": dst.path,
                "_async": true,
            ])
        } else {
            // Google Drive paths are not unique, so files must be copied by ID.
            response = try await rc("backend/command", body: [
                "command": "copyid",
                "fs": "\(Self.remoteName):",
                "arg": [id, dst.path],
                "_async": true,
            ])
        }

        if let jobID = intValue(response["jobid"]) {
            return String(jobID)
        }
        // backend/command may return the error inline without a job id
        if let err = response["error"] as? String, !err.isEmpty {
            throw AppError.rcloneFailed(err)
        }
        throw AppError.rcloneFailed("Couldn’t start copy.")
    }

    func stats() async throws -> TransferStats {
        let json = try await rc("core/stats", body: [:])
        var stats = TransferStats()
        stats.bytes = int64(json["bytes"])
        stats.totalBytes = int64(json["totalBytes"])
        stats.speed = doubleValue(json["speed"])
        let eta = doubleValue(json["eta"])
        stats.eta = eta > 0 ? eta : nil
        stats.errors = Int(int64(json["errors"]))
        stats.checks = Int(int64(json["checks"]))
        stats.transfers = Int(int64(json["transfers"]))
        if let list = json["transferring"] as? [[String: Any]] {
            stats.transferring = list.compactMap { $0["name"] as? String }
        }
        return stats
    }

    func resetStats() async throws {
        _ = try await rc("core/stats-reset", body: [:])
    }

    func jobStatus(_ jobID: String) async throws -> (finished: Bool, error: String?) {
        let json = try await rc("job/status", body: ["jobid": Int(jobID) ?? jobID])
        let finished = (json["finished"] as? Bool) ?? false
        let error = json["error"] as? String
        let succeeded = (json["success"] as? Bool) ?? false
        if finished, !succeeded, error?.isEmpty != false {
            return (true, "The download engine stopped without completing the transfer.")
        }
        return (finished, (error?.isEmpty == false) ? error : nil)
    }

    func stopJob(_ jobID: String) async {
        _ = try? await rc("job/stop", body: ["jobid": Int(jobID) ?? jobID])
    }

    nonisolated static func sanitizeFileName(_ name: String) -> String {
        let illegal = CharacterSet(charactersIn: "<>:\"/\\|?*")
        let parts = name.components(separatedBy: illegal)
        let cleaned = parts.joined(separator: "_").trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "download" : cleaned
    }

    nonisolated static func destinationFileName(
        name: String,
        isFolder: Bool,
        mimeType: String?
    ) -> String {
        var fileName = sanitizeFileName(name)
        guard !isFolder,
              let mimeType,
              let ext = DriveItem.exportFileExtension(forMimeType: mimeType)
        else {
            return fileName
        }
        let suffix = ".\(ext)"
        if !fileName.lowercased().hasSuffix(suffix) {
            fileName += suffix
        }
        return fileName
    }

    private func ping() async -> Bool {
        (try? await rc("rc/noop", body: [:])) != nil
    }

    private func rc(_ path: String, body: [String: Any]) async throws -> [String: Any] {
        let url = URL(string: "http://127.0.0.1:\(rcPort)/\(path)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let auth = Data("\(rcUser):\(rcPass)".utf8).base64EncodedString()
        request.setValue("Basic \(auth)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AppError.rcloneFailed("No response from engine.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw AppError.rcloneFailed(message)
        }
        if data.isEmpty { return [:] }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private static func reserveEphemeralPort() throws -> UInt16 {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else {
            throw AppError.rcloneFailed("Couldn’t reserve a local port for the download engine.")
        }
        defer { close(sock) }

        var reuse: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        addr.sin_port = 0

        let bindResult = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            throw AppError.rcloneFailed("Couldn’t bind a local port for the download engine.")
        }

        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(sock, $0, &length)
            }
        }
        guard nameResult == 0 else {
            throw AppError.rcloneFailed("Couldn’t read the reserved local port.")
        }
        return UInt16(bigEndian: addr.sin_port)
    }

    private static func restrictToOwner(_ url: URL) {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    private static func randomPassword() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status == errSecSuccess {
            return Data(bytes).base64EncodedString()
        }
        return UUID().uuidString
    }

    private func int64(_ value: Any?) -> Int64 {
        if let n = value as? Int64 { return n }
        if let n = value as? Int { return Int64(n) }
        if let n = value as? Double { return Int64(n) }
        if let n = value as? NSNumber { return n.int64Value }
        return 0
    }

    private func intValue(_ value: Any?) -> Int? {
        if let n = value as? Int { return n }
        if let n = value as? NSNumber { return n.intValue }
        return nil
    }

    private func doubleValue(_ value: Any?) -> Double {
        if let n = value as? Double { return n }
        if let n = value as? NSNumber { return n.doubleValue }
        return 0
    }
}
