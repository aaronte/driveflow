import Foundation
import Combine
import AppKit

@MainActor
final class DownloadController: ObservableObject {
    @Published var stats = TransferStats()
    @Published var activeJobID: UUID?
    @Published var lastError: AppError?
    @Published private(set) var isEngineReady = false

    private let store = JobStore()
    private let auth: AuthSession
    private let drive: DriveClient
    private let engine = RcloneEngine()
    private var pollTask: Task<Void, Never>?
    private var activity: NSObjectProtocol?
    private var storeObservation: AnyCancellable?

    init(auth: AuthSession, drive: DriveClient) {
        self.auth = auth
        self.drive = drive
        storeObservation = store.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in
                self?.objectWillChange.send()
            }
        }
    }

    var jobs: [DownloadJob] { store.jobs }

    func job(id: UUID) -> DownloadJob? {
        store.job(id: id)
    }

    /// Terminates the rclone child immediately (app quit). Safe without awaiting.
    nonisolated func terminateEngineForShutdown() {
        engine.terminateProcessForShutdown()
    }

    var pendingItemCount: Int {
        store.jobs
            .filter { $0.status == .running || $0.status == .queued }
            .reduce(0) { $0 + $1.items.count }
    }

    var queuedJobCount: Int {
        store.jobs.filter { $0.status == .queued }.count
    }

    func prepareEngine() async {
        do {
            try await engine.ensureRunning()
            try await injectToken()
            isEngineReady = true
        } catch let error as AppError {
            lastError = error
            isEngineReady = false
        } catch {
            lastError = .rcloneFailed(error.localizedDescription)
            isEngineReady = false
        }
    }

    func enqueue(items: [DriveItem], destination: DestinationInfo) async {
        lastError = nil
        do {
            try DestinationPicker.ensureSpace(needed: items.compactMap(\.size).reduce(0, +), on: destination)
            if let warning = destination.warning {
                lastError = .volumeWarning(warning)
            }
            let job = DownloadJob(items: items, destination: destination.url)
            store.upsert(job)
            if activeJobID == nil {
                await startNextQueued()
            }
        } catch let error as AppError {
            lastError = error
        } catch {
            lastError = .unknown(error.localizedDescription)
        }
    }

    func start(jobID: UUID) async {
        guard var job = store.job(id: jobID) else { return }
        guard activeJobID == nil || activeJobID == jobID else {
            store.update(jobID) {
                $0.status = .queued
                $0.errorMessage = nil
            }
            return
        }
        var startedRcloneJobIDs: [String] = []
        do {
            try await injectToken()
            try await engine.resetStats()
            beginActivity()
            job.status = .running
            job.errorMessage = nil
            job.rcloneJobIDs = []
            store.upsert(job)
            activeJobID = job.id
            stats = TransferStats(totalBytes: job.totalBytes)

            let dest = URL(fileURLWithPath: job.destinationPath)
            for index in job.items.indices {
                var item = job.items[index]
                // Confirm ambiguous items (no extension) against Drive so folders
                // aren't sent through file copyid.
                let ext = (item.name as NSString).pathExtension
                if !item.isFolder, !item.isSharedDriveRoot, ext.isEmpty {
                    item.isFolder = (try? await drive.isFolder(id: item.id)) ?? false
                    job.items[index] = item
                }
                // drive.file often does not grant children of a picked folder.
                if item.isFolder || item.isSharedDriveRoot {
                    try await drive.assertFolderChildrenAccessible(id: item.id)
                }
                let rcloneJobID = try await engine.copyItem(
                    id: item.id,
                    name: item.name,
                    isFolder: item.isFolder || item.isSharedDriveRoot,
                    isSharedDriveRoot: item.isSharedDriveRoot,
                    mimeType: item.mimeType,
                    destination: dest
                )
                startedRcloneJobIDs.append(rcloneJobID)
                job.rcloneJobIDs = startedRcloneJobIDs
                store.upsert(job)
            }
            startPolling(jobID: job.id)
        } catch let error as AppError {
            await failClosedStart(jobID: jobID, startedIDs: startedRcloneJobIDs)
            store.update(jobID) {
                $0.status = .failed
                $0.errorMessage = error.localizedDescription
                $0.rcloneJobIDs = []
            }
            lastError = error
            await startNextQueued()
        } catch {
            await failClosedStart(jobID: jobID, startedIDs: startedRcloneJobIDs)
            store.update(jobID) {
                $0.status = .failed
                $0.errorMessage = error.localizedDescription
                $0.rcloneJobIDs = []
            }
            lastError = .rcloneFailed(error.localizedDescription)
            await startNextQueued()
        }
    }

    func pause(jobID: UUID) async {
        let wasActive = detachActiveTransfer(ifJobID: jobID)
        if let job = store.job(id: jobID) {
            for rcloneJobID in job.rcloneJobIDs {
                await engine.stopJob(rcloneJobID)
            }
        }
        store.update(jobID) {
            $0.status = .paused
            $0.rcloneJobIDs = []
            $0.errorMessage = "Paused. Resume to restart this transfer."
        }
        if wasActive {
            await startNextQueued()
        }
    }

    func resume(jobID: UUID) async {
        store.update(jobID) {
            $0.status = .queued
            $0.errorMessage = nil
            $0.rcloneJobIDs = []
        }
        if activeJobID == nil {
            await startNextQueued()
        }
    }

    func cancel(jobID: UUID) async {
        let wasActive = detachActiveTransfer(ifJobID: jobID)
        if let job = store.job(id: jobID) {
            for rcloneJobID in job.rcloneJobIDs {
                await engine.stopJob(rcloneJobID)
            }
        }
        store.update(jobID) {
            $0.status = .cancelled
            $0.rcloneJobIDs = []
        }
        if wasActive {
            await startNextQueued()
        }
    }

    /// Call on Google sign-out so rclone config, live jobs, and Drive cache are wiped.
    func clearEngineCredentials() async {
        store.abandonLiveTransfers(
            message: "Signed out before this transfer finished. Sign in and resume to restart it."
        )
        await engine.clearPersistedCredentials()
        await drive.invalidateCache()
        isEngineReady = false
        activeJobID = nil
        pollTask?.cancel()
        pollTask = nil
        stats = TransferStats()
        endActivity()
    }

    /// Stop any rclone jobs already started before a mid-start failure.
    private func failClosedStart(jobID: UUID, startedIDs: [String]) async {
        for rcloneJobID in startedIDs {
            await engine.stopJob(rcloneJobID)
        }
        _ = detachActiveTransfer(ifJobID: jobID)
    }

    private func injectToken() async throws {
        try await engine.configureDrive(tokenJSON: try await auth.rcloneTokenJSON())
    }

    private func startPolling(jobID: UUID) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            guard let self else { return }
            var consecutiveFailures = 0
            while !Task.isCancelled {
                guard self.isPolling(jobID) else { return }
                do {
                    let stats = try await engine.stats()
                    guard self.isPolling(jobID) else { return }
                    self.stats = stats
                    store.update(jobID) {
                        guard $0.status == .running else { return }
                        $0.bytesTransferred = stats.bytes
                        if stats.totalBytes > 0 { $0.totalBytes = stats.totalBytes }
                    }

                    guard let job = store.job(id: jobID), job.status == .running else { return }
                    let rcloneJobIDs = job.rcloneJobIDs
                    var allFinished = !rcloneJobIDs.isEmpty
                    var jobError: String?

                    for rcloneJobID in rcloneJobIDs {
                        let status = try await engine.jobStatus(rcloneJobID)
                        allFinished = allFinished && status.finished
                        if let error = status.error {
                            jobError = error
                            break
                        }
                    }

                    guard self.isPolling(jobID) else { return }

                    if let jobError {
                        await fail(jobID: jobID, message: jobError)
                        return
                    }
                    if allFinished {
                        store.update(jobID) {
                            guard $0.status == .running else { return }
                            $0.status = .completed
                            $0.bytesTransferred = max($0.bytesTransferred, $0.totalBytes)
                        }
                        if detachActiveTransfer(ifJobID: jobID) {
                            await startNextQueued()
                        }
                        return
                    }
                    consecutiveFailures = 0
                } catch {
                    guard self.isPolling(jobID) else { return }
                    consecutiveFailures += 1
                    if consecutiveFailures >= 3 {
                        await fail(
                            jobID: jobID,
                            message: "Lost contact with the download engine. \(error.localizedDescription)"
                        )
                        return
                    }
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    private func isPolling(_ jobID: UUID) -> Bool {
        activeJobID == jobID && store.job(id: jobID)?.status == .running
    }

    /// Clears live-transfer UI/engine bookkeeping for `jobID` if it is active.
    @discardableResult
    private func detachActiveTransfer(ifJobID jobID: UUID) -> Bool {
        guard activeJobID == jobID else { return false }
        activeJobID = nil
        pollTask?.cancel()
        pollTask = nil
        stats = TransferStats()
        endActivity()
        return true
    }

    private func startNextQueued() async {
        guard activeJobID == nil,
              let next = store.jobs.last(where: { $0.status == .queued })
        else { return }
        await start(jobID: next.id)
    }

    private func fail(jobID: UUID, message: String) async {
        let wasActive = detachActiveTransfer(ifJobID: jobID)
        store.update(jobID) {
            // Don't overwrite cancelled/paused with a late failure from a racing poll.
            guard $0.status == .running || $0.status == .queued else { return }
            $0.status = .failed
            $0.errorMessage = message
            $0.rcloneJobIDs = []
        }
        lastError = .rcloneFailed(message)
        if wasActive {
            await startNextQueued()
        }
    }

    private func beginActivity() {
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .userInitiated],
            reason: "Driveflow is downloading files"
        )
    }

    private func endActivity() {
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }
}
