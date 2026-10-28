import Foundation
import SwiftUI

@MainActor
final class DriveBrowserModel: ObservableObject {
    @Published private(set) var breadcrumbs: [DriveBreadcrumb] = [
        DriveBreadcrumb(id: BoundFolderBrowse.rootCrumbID, name: BoundFolderBrowse.rootTitle)
    ]
    @Published private(set) var items: [DriveItem] = []
    @Published private(set) var boundFolders: [BoundFolderSummary] = []
    @Published private(set) var selectedFolderID: String?
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published var selectedIDs: Set<String> = []
    @Published var searchText = ""
    @Published var lastError: AppError?

    private let client: DriveClient
    private weak var driveAccess: DriveAccessSession?
    private var nextPageToken: String?
    private var searchTask: Task<Void, Never>?

    init(client: DriveClient, driveAccess: DriveAccessSession? = nil) {
        self.client = client
        self.driveAccess = driveAccess
    }

    func attach(driveAccess: DriveAccessSession) {
        self.driveAccess = driveAccess
    }

    var selectedItems: [DriveItem] {
        items.filter { selectedIDs.contains($0.id) }
    }

    private var boundFolderIDs: Set<String> {
        driveAccess?.boundFolderIDs ?? []
    }

    func bootstrap() async {
        await reloadBoundFolders(preferredID: driveAccess?.preferredFolderID)
    }

    func reloadBoundFolders(preferredID: String?) async {
        let records = driveAccess?.orderedBoundFolders() ?? []
        boundFolders = records.map { record in
            BoundFolderSummary(
                id: record.id.raw,
                name: record.name ?? "Shared folder",
                itemCount: nil,
                itemCountIsLowerBound: false
            )
        }
        let selection = preferredID.flatMap { id in
            boundFolders.contains(where: { $0.id == id }) ? id : nil
        } ?? selectedFolderID.flatMap { id in
            boundFolders.contains(where: { $0.id == id }) ? id : nil
        } ?? boundFolders.first?.id

        if let selection {
            await showBoundFolder(selection, resetStack: true)
        } else {
            selectedFolderID = nil
            items = []
            breadcrumbs = [
                DriveBreadcrumb(id: BoundFolderBrowse.rootCrumbID, name: BoundFolderBrowse.rootTitle)
            ]
        }

        for record in records {
            do {
                let summary = try await client.folderSummary(id: record.id.raw)
                guard driveAccess?.boundFolderIDs.contains(record.id.raw) == true else { continue }
                if let index = boundFolders.firstIndex(where: { $0.id == record.id.raw }) {
                    boundFolders[index] = summary
                }
                driveAccess?.rememberFolderName(id: summary.id, name: summary.name)
                if selectedFolderID == record.id.raw,
                   breadcrumbs.count >= 2,
                   breadcrumbs[1].id == record.id.raw {
                    breadcrumbs[1] = DriveBreadcrumb(id: record.id.raw, name: summary.name)
                }
            } catch is CancellationError {
                return
            } catch {
                // Keep the stored name until Drive answers.
            }
        }
    }

    func showBoundFolder(_ id: String, resetStack: Bool) async {
        let known = boundFolders.contains(where: { $0.id == id }) || boundFolderIDs.contains(id)
        guard known else { return }
        let name = boundFolders.first(where: { $0.id == id })?.name ?? "Shared folder"
        selectedFolderID = id
        if resetStack || breadcrumbs.last?.id != id {
            breadcrumbs = [
                DriveBreadcrumb(id: BoundFolderBrowse.rootCrumbID, name: BoundFolderBrowse.rootTitle),
                DriveBreadcrumb(id: id, name: name),
            ]
        }
        searchText = ""
        selectedIDs.removeAll()
        await reload()
    }

    func reload() async {
        isLoading = true
        lastError = nil
        nextPageToken = nil
        defer { isLoading = false }
        guard let parent = listParentID else {
            items = []
            return
        }
        do {
            let result = try await client.list(parentID: parent)
            items = result.items
            nextPageToken = result.nextPageToken
        } catch let error as AppError {
            lastError = error
            items = []
        } catch {
            lastError = .driveAPI(error.localizedDescription)
            items = []
        }
    }

    func loadMoreIfNeeded(current item: DriveItem) async {
        guard let nextPageToken, !isLoadingMore, items.last?.id == item.id else { return }
        guard let parent = listParentID else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let result = try await client.list(
                parentID: parent,
                pageToken: nextPageToken
            )
            items.append(contentsOf: result.items)
            self.nextPageToken = result.nextPageToken
        } catch {
            // Soft-fail pagination
        }
    }

    func open(_ item: DriveItem) async {
        guard item.isFolder else { return }
        selectedIDs.removeAll()
        breadcrumbs.append(DriveBreadcrumb(id: item.id, name: item.name))
        await reload()
    }

    func goToBreadcrumb(_ crumb: DriveBreadcrumb) async {
        if crumb.id == BoundFolderBrowse.rootCrumbID {
            guard let folderID = selectedFolderID else { return }
            await showBoundFolder(folderID, resetStack: true)
            return
        }
        guard let index = breadcrumbs.firstIndex(of: crumb), index > 0 else { return }
        breadcrumbs = Array(breadcrumbs.prefix(index + 1))
        selectedIDs.removeAll()
        await reload()
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

    /// Drop listings/selection so a later account can't briefly see the previous one.
    func resetForSignOut() {
        searchTask?.cancel()
        searchTask = nil
        selectedIDs.removeAll()
        items = []
        boundFolders = []
        selectedFolderID = nil
        searchText = ""
        nextPageToken = nil
        lastError = nil
        breadcrumbs = [
            DriveBreadcrumb(id: BoundFolderBrowse.rootCrumbID, name: BoundFolderBrowse.rootTitle)
        ]
    }

    func runSearch() {
        searchTask?.cancel()
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            Task { await reload() }
            return
        }
        let bound = boundFolderIDs
        searchTask = Task {
            isLoading = true
            defer { isLoading = false }
            do {
                let found = try await client.search(query: query, boundFolderIDs: bound)
                if Task.isCancelled { return }
                items = found
                nextPageToken = nil
            } catch is CancellationError {
                return
            } catch let error as AppError {
                lastError = error
            } catch {
                lastError = .driveAPI(error.localizedDescription)
            }
        }
    }

    private var listParentID: String? {
        guard let last = breadcrumbs.last, last.id != BoundFolderBrowse.rootCrumbID else {
            return nil
        }
        return last.id
    }
}
