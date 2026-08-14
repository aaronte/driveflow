import Foundation
import Combine

@MainActor
final class JobStore: ObservableObject {
    @Published private(set) var jobs: [DownloadJob] = []

    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Driveflow", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("jobs.json")
    }()

    private var lastPersist = Date.distantPast
    private let persistInterval: TimeInterval = 3

    init() {
        load()
    }

    func upsert(_ job: DownloadJob) {
        let statusChanged: Bool
        if let index = jobs.firstIndex(where: { $0.id == job.id }) {
            statusChanged = jobs[index].status != job.status
            jobs[index] = job
        } else {
            statusChanged = true
            jobs.insert(job, at: 0)
        }
        persist(force: statusChanged)
    }

    func update(_ id: UUID, mutate: (inout DownloadJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        var job = jobs[index]
        let previousStatus = job.status
        mutate(&job)
        job.updatedAt = Date()
        let statusChanged = job.status != previousStatus
        jobs[index] = job
        persist(force: statusChanged)
    }

    func job(id: UUID) -> DownloadJob? {
        jobs.first { $0.id == id }
    }

    /// Same policy as cold start: live jobs can't outlive the engine process / session.
    func abandonLiveTransfers(message: String) {
        var changed = false
        for index in jobs.indices {
            guard jobs[index].status == .running || jobs[index].status == .queued else { continue }
            jobs[index].status = .paused
            jobs[index].rcloneJobIDs = []
            jobs[index].errorMessage = message
            jobs[index].updatedAt = Date()
            changed = true
        }
        if changed {
            persist(force: true)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([DownloadJob].self, from: data) else {
            jobs = []
            return
        }
        jobs = decoded.sorted { $0.createdAt > $1.createdAt }
        abandonLiveTransfers(
            message: "Driveflow closed before this transfer finished. Resume to restart it."
        )
    }

    private func persist(force: Bool = false) {
        let now = Date()
        if !force, now.timeIntervalSince(lastPersist) < persistInterval {
            return
        }
        lastPersist = now
        guard let data = try? JSONEncoder().encode(jobs) else { return }
        try? data.write(to: fileURL, options: [.atomic])
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }
}
