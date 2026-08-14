import SwiftUI

struct TransfersView: View {
    @ObservedObject var downloads: DownloadController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Transfers")
                        .font(.system(size: 24, weight: .semibold))
                        .tracking(-0.4)
                    Text(queueSummary)
                        .font(.system(size: 12))
                        .foregroundStyle(DriveflowTheme.inkMuted)
                }
                Spacer()
            }

            if let activeJob {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(DriveflowTheme.accent)
                            .frame(width: 6, height: 6)
                        Text("Now downloading")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(DriveflowTheme.accent)
                            .textCase(.uppercase)
                        Spacer()
                        Text(activeTimingLabel)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(DriveflowTheme.inkMuted)
                    }

                    Text(downloads.stats.transferring.first ?? activeJob.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DriveflowTheme.ink)
                        .lineLimit(1)

                    ProgressView(value: activeFraction)
                        .tint(DriveflowTheme.accent)

                    Text(activeProgressLabel)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(DriveflowTheme.inkMuted)
                }
                .padding(18)
                .background(
                    DriveflowTheme.paper,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
            }

            if downloads.jobs.isEmpty {
                Text("No downloads yet.")
                    .foregroundStyle(DriveflowTheme.inkMuted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(downloads.jobs) { job in
                    transferRow(for: job)
                        .padding(14)
                        .background(
                            DriveflowTheme.paper.opacity(0.86),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                        )
                        .listRowInsets(
                            EdgeInsets(top: 5, leading: 0, bottom: 5, trailing: 0)
                        )
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        // Stable identity so ProgressView state doesn't bleed onto
                        // cancelled/failed rows when a new transfer starts.
                        .id(job.id)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(DriveflowTheme.canvas)
    }

    @ViewBuilder
    private func transferRow(for job: DownloadJob) -> some View {
        let isActiveTransfer = job.id == downloads.activeJobID && job.status == .running

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(job.title)
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Text(statusLabel(for: job.status))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(statusColor(for: job.status))
            }
            Text(job.destinationPath)
                .font(.system(size: 11))
                .foregroundStyle(DriveflowTheme.inkMuted)
                .lineLimit(1)

            // Only the live transfer may show progress — never cancelled/failed
            // rows, and never borrow global rclone stats onto a stale job.
            if isActiveTransfer {
                let total = max(job.totalBytes, downloads.stats.totalBytes)
                if total > 0 {
                    ProgressView(
                        value: Double(max(job.bytesTransferred, downloads.stats.bytes)),
                        total: Double(total)
                    )
                    .progressViewStyle(.linear)
                    .tint(DriveflowTheme.accent)
                    .id("\(job.id)-progress")
                }
            }

            if let errorMessage = job.errorMessage, job.status != .cancelled {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(
                        job.status == .failed
                            ? DriveflowTheme.caution
                            : DriveflowTheme.inkMuted
                    )
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 14) {
                if job.status == .running {
                    Button("Pause") {
                        Task { await downloads.pause(jobID: job.id) }
                    }
                }
                if job.status == .paused || job.status == .failed {
                    Button("Resume") {
                        Task { await downloads.resume(jobID: job.id) }
                    }
                }
                if job.status == .running || job.status == .paused || job.status == .queued {
                    Button("Cancel") {
                        Task { await downloads.cancel(jobID: job.id) }
                    }
                }
            }
            .buttonStyle(GhostButtonStyle(accent: true))
            .font(.system(size: 12, weight: .semibold))
        }
    }

    private var queueSummary: String {
        if downloads.pendingItemCount == 0 {
            return "No active downloads. Return to Browse to add files."
        }
        if downloads.queuedJobCount == 0 {
            return "\(downloads.pendingItemCount) item\(downloads.pendingItemCount == 1 ? "" : "s") downloading."
        }
        return "\(downloads.pendingItemCount) items downloading or queued across \(downloads.queuedJobCount + 1) transfers."
    }

    private var activeJob: DownloadJob? {
        guard let id = downloads.activeJobID else { return nil }
        return downloads.job(id: id)
    }

    private var activeFraction: Double {
        guard let activeJob else { return 0 }
        let total = max(activeJob.totalBytes, downloads.stats.totalBytes)
        guard total > 0 else { return 0 }
        let bytes = max(activeJob.bytesTransferred, downloads.stats.bytes)
        return min(1, Double(bytes) / Double(total))
    }

    private var activeProgressLabel: String {
        guard let activeJob else { return "Preparing…" }
        let bytes = max(activeJob.bytesTransferred, downloads.stats.bytes)
        let total = max(activeJob.totalBytes, downloads.stats.totalBytes)
        if total > 0 {
            return "\(fileSize(bytes)) of \(fileSize(total))"
        }
        return bytes > 0 ? fileSize(bytes) : "Preparing…"
    }

    private var activeTimingLabel: String {
        if downloads.stats.speed > 0 {
            let eta = downloads.stats.etaLabel
            return eta == "—"
                ? downloads.stats.speedLabel
                : "\(downloads.stats.speedLabel) · ETA \(eta)"
        }
        return "Starting…"
    }

    private func statusLabel(for status: JobStatus) -> String {
        switch status {
        case .queued:
            return "QUEUED"
        case .running:
            return "DOWNLOADING"
        case .paused:
            return "PAUSED"
        case .completed:
            return "COMPLETE"
        case .failed:
            return "FAILED"
        case .cancelled:
            return "CANCELLED"
        }
    }

    private func statusColor(for status: JobStatus) -> Color {
        switch status {
        case .running, .completed:
            return DriveflowTheme.accent
        case .failed:
            return DriveflowTheme.caution
        case .queued, .paused, .cancelled:
            return DriveflowTheme.inkFaint
        }
    }

    private func fileSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
