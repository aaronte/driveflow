import Foundation
import SwiftUI

@MainActor
final class DriveBrowserModel: ObservableObject {
    @Published var root: DriveRoot = .myDrive
    @Published private(set) var breadcrumbs: [DriveBreadcrumb] = [DriveBreadcrumb(id: "root", name: "My Drive")]
    @Published private(set) var items: [DriveItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published var selectedIDs: Set<String> = []
    @Published var searchText = ""
    @Published var lastError: AppError?

    private let client: DriveClient
    private var nextPageToken: String?
    private var searchTask: Task<Void, Never>?

    init(client: DriveClient) {
        self.client = client
    }

    var selectedItems: [DriveItem] {
        items.filter { selectedIDs.contains($0.id) }
    }

    func bootstrap() async {
        breadcrumbs = [DriveBreadcrumb(id: "root", name: root.title)]
        await reload()
    }

    func switchRoot(_ newRoot: DriveRoot) async {
        root = newRoot
        selectedIDs.removeAll()
        breadcrumbs = [DriveBreadcrumb(id: "root", name: newRoot.title)]
        await reload()
    }

    func reload() async {
        isLoading = true
        lastError = nil
        nextPageToken = nil
        defer { isLoading = false }
        do {
            let parent = breadcrumbs.count > 1 ? breadcrumbs.last?.id : nil
            let result = try await client.list(parentID: parent == "root" ? nil : parent, root: root)
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
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let parent = breadcrumbs.count > 1 ? breadcrumbs.last?.id : nil
            let result = try await client.list(
                parentID: parent == "root" ? nil : parent,
                root: root,
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
        guard let index = breadcrumbs.firstIndex(of: crumb) else { return }
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
        selectedIDs.removeAll()
        items = []
        searchText = ""
        nextPageToken = nil
        lastError = nil
        breadcrumbs = [DriveBreadcrumb(id: "root", name: root.title)]
    }

    func runSearch() {
        searchTask?.cancel()
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            Task { await reload() }
            return
        }
        searchTask = Task {
            isLoading = true
            defer { isLoading = false }
            do {
                items = try await client.search(query: query)
                nextPageToken = nil
            } catch let error as AppError {
                lastError = error
            } catch {
                lastError = .driveAPI(error.localizedDescription)
            }
        }
    }
}
