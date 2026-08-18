import Foundation
import SwiftUI

/// Session list of files the user granted through Google’s desktop Picker.
/// Does not browse My Drive / Shared with me.
@MainActor
final class DriveBrowserModel: ObservableObject {
    @Published private(set) var items: [DriveItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isPicking = false
    @Published var selectedIDs: Set<String> = []
    @Published var lastError: AppError?

    private let auth: AuthSession
    private let client: DriveClient

    init(auth: AuthSession, client: DriveClient) {
        self.auth = auth
        self.client = client
    }

    var selectedItems: [DriveItem] {
        items.filter { selectedIDs.contains($0.id) }
    }

    /// After sign-in, load metadata for file IDs returned by the Picker redirect.
    func bootstrap() async {
        let ids = auth.lastPickedFileIDs
        guard !ids.isEmpty else { return }
        await ingestPickedFileIDs(ids, selectNew: true)
    }

    func chooseFromGoogleDrive() async {
        lastError = nil
        isPicking = true
        defer { isPicking = false }
        do {
            let ids = try await auth.pickAdditionalFiles()
            guard !ids.isEmpty else { return }
            await ingestPickedFileIDs(ids, selectNew: true)
        } catch let error as AppError {
            if case .authCancelled = error { return }
            lastError = error
        } catch {
            lastError = .authFailed(error.localizedDescription)
        }
    }

    func ingestPickedFileIDs(_ ids: [String], selectNew: Bool) async {
        let unique = Array(Set(ids)).filter { id in !items.contains(where: { $0.id == id }) }
        guard !unique.isEmpty else {
            // Re-picked files already in the list — select them.
            if selectNew {
                for id in ids where items.contains(where: { $0.id == id }) {
                    selectedIDs.insert(id)
                }
            }
            return
        }
        isLoading = true
        lastError = nil
        defer { isLoading = false }
        do {
            let fetched = try await client.files(ids: unique)
            items.append(contentsOf: fetched)
            items.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            if selectNew {
                for item in fetched {
                    selectedIDs.insert(item.id)
                }
            }
        } catch let error as AppError {
            lastError = error
        } catch {
            lastError = .driveAPI(error.localizedDescription)
        }
    }

    func toggleSelection(_ item: DriveItem) {
        if selectedIDs.contains(item.id) {
            selectedIDs.remove(item.id)
        } else {
            selectedIDs.insert(item.id)
        }
    }

    func clearSelection() {
        selectedIDs.removeAll()
    }

    func removeFromSession(_ item: DriveItem) {
        items.removeAll { $0.id == item.id }
        selectedIDs.remove(item.id)
    }

    /// Drop listings/selection so a later account can't briefly see the previous one.
    func resetForSignOut() {
        selectedIDs.removeAll()
        items = []
        lastError = nil
        isLoading = false
        isPicking = false
    }
}
