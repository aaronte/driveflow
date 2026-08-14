import AppKit
import Foundation

struct DestinationInfo: Sendable, Equatable {
    let url: URL
    let volumeName: String
    let freeBytes: Int64
    let fileSystem: String

    var warning: String? {
        let fs = fileSystem.uppercased()
        if fs.contains("FAT32") || fs.contains("MSDOS") {
            return "This volume looks like FAT32. Files larger than 4 GB will fail."
        }
        if fs.contains("EXFAT") {
            return "exFAT can reject some characters in Google Drive filenames. Driveflow will sanitize names when needed."
        }
        return nil
    }
}

enum DestinationPicker {
    @MainActor
    static func chooseFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose where Driveflow should download files."
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func inspect(_ url: URL) throws -> DestinationInfo {
        let values = try url.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
            .volumeNameKey,
            .volumeLocalizedFormatDescriptionKey,
        ])
        let free = values.volumeAvailableCapacityForImportantUsage
            ?? Int64(values.volumeAvailableCapacity ?? 0)
        return DestinationInfo(
            url: url,
            volumeName: values.volumeName ?? url.lastPathComponent,
            freeBytes: free,
            fileSystem: values.volumeLocalizedFormatDescription ?? "Unknown"
        )
    }

    static func ensureSpace(needed: Int64, on destination: DestinationInfo) throws {
        // Folders may report 0 until expanded; require headroom when we know size.
        guard needed > 0 else { return }
        let headroom: Int64 = 64 * 1024 * 1024
        if destination.freeBytes < needed + headroom {
            throw AppError.insufficientSpace(needed: needed + headroom, available: destination.freeBytes)
        }
    }
}
