import SwiftUI

private enum WorkspaceSection {
    case browse
    case transfers
}

struct BrowserView: View {
    @ObservedObject var auth: AuthSession
    @ObservedObject var browser: DriveBrowserModel
    @ObservedObject var downloads: DownloadController

    @State private var destination: DestinationInfo?
    @State private var section: WorkspaceSection = .browse

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 180, idealWidth: 200, maxWidth: 240)
            mainColumn
        }
        .background(DriveflowTheme.canvas)
        .task {
            await browser.bootstrap()
            await downloads.prepareEngine()
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 10) {
                Image("AppLogo")
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 28, height: 28)
                Text("Driveflow")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(DriveflowTheme.ink)
            }
            .padding(.top, 8)

            VStack(alignment: .leading, spacing: 8) {
                Text("This session")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DriveflowTheme.inkFaint)
                    .textCase(.uppercase)
                    .tracking(0.5)
                Text(
                    browser.items.isEmpty
                        ? "No files chosen yet"
                        : "\(browser.items.count) file\(browser.items.count == 1 ? "" : "s") chosen"
                )
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(DriveflowTheme.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            if let email = auth.userEmail {
                Text(email)
                    .font(.system(size: 11))
                    .foregroundStyle(DriveflowTheme.inkFaint)
                    .lineLimit(1)
            }
            Button("Sign out") {
                Task {
                    await downloads.clearEngineCredentials()
                    browser.resetForSignOut()
                    auth.signOut()
                }
            }
                .buttonStyle(GhostButtonStyle())
                .font(.system(size: 12, weight: .medium))
        }
        .padding(16)
        .background(DriveflowTheme.paper)
    }

    private var mainColumn: some View {
        VStack(spacing: 0) {
            workspaceNavigation
            if section == .browse {
                browseWorkspace
            } else {
                TransfersView(downloads: downloads)
            }
        }
    }

    private var workspaceNavigation: some View {
        HStack(spacing: 4) {
            Button {
                section = .browse
            } label: {
                Label("Browse", systemImage: "folder")
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(WorkspaceTabButtonStyle(isSelected: section == .browse))

            Button {
                section = .transfers
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "arrow.down.circle")
                    Text("Transfers")
                    if downloads.pendingItemCount > 0 {
                        Text("\(downloads.pendingItemCount)")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(DriveflowTheme.onAccent)
                            .frame(minWidth: 17, minHeight: 17)
                            .background(
                                DriveflowTheme.accent,
                                in: Capsule()
                            )
                            .accessibilityLabel(
                                "\(downloads.pendingItemCount) items downloading or queued"
                            )
                    }
                }
                .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(WorkspaceTabButtonStyle(isSelected: section == .transfers))

            Spacer()

            if downloads.activeJobID != nil {
                HStack(spacing: 7) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(DriveflowTheme.accent)
                    Text(
                        downloads.stats.speed > 0
                            ? downloads.stats.speedLabel
                            : "Starting…"
                    )
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(DriveflowTheme.inkMuted)
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(DriveflowTheme.paper)
    }

    private var browseWorkspace: some View {
        VStack(spacing: 0) {
            toolbar
            content
            footer
        }
    }

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 14) {
            StepLabel(title: "Choose files")
            HStack(spacing: 12) {
                Button {
                    Task { await browser.chooseFromGoogleDrive() }
                } label: {
                    HStack(spacing: 8) {
                        if browser.isPicking || auth.isBusy {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(
                            browser.isPicking || auth.isBusy
                                ? "Opening Google…"
                                : "Choose from Google Drive"
                        )
                        .font(.system(size: 13, weight: .semibold))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
                .buttonStyle(PrimaryFillButtonStyle(enabled: !browser.isPicking && !auth.isBusy))
                .disabled(browser.isPicking || auth.isBusy)

                if !browser.selectedIDs.isEmpty {
                    Button("Clear selection") {
                        browser.clearSelection()
                    }
                    .buttonStyle(GhostButtonStyle())
                    .font(.system(size: 12, weight: .medium))
                }

                Spacer()
            }
            Text("Google’s picker grants access only to the files you select. Driveflow does not list your whole Drive.")
                .font(.system(size: 12))
                .foregroundStyle(DriveflowTheme.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
    }

    private var content: some View {
        Group {
            if browser.isLoading && browser.items.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if browser.items.isEmpty {
                VStack(spacing: 8) {
                    Text("No files yet")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(DriveflowTheme.ink)
                    Text("Choose files in Google’s picker, then pick a destination and download.")
                        .font(.system(size: 13))
                        .foregroundStyle(DriveflowTheme.inkMuted)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(browser.items) { item in
                    itemRow(item)
                        .listRowBackground(Color.clear)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private func itemRow(_ item: DriveItem) -> some View {
        let selected = browser.selectedIDs.contains(item.id)
        return HStack(spacing: 12) {
            Image(systemName: item.isFolder ? "folder.fill" : "doc")
                .foregroundStyle(item.isFolder ? DriveflowTheme.accent : DriveflowTheme.inkMuted)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(DriveflowTheme.ink)
                    .lineLimit(1)
                Text(itemSubtitle(item))
                    .font(.system(size: 11))
                    .foregroundStyle(DriveflowTheme.inkFaint)
            }
            Spacer()
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(selected ? DriveflowTheme.accent : DriveflowTheme.inkFaint)
        }
        .contentShape(Rectangle())
        .hoverableRow(isSelected: selected)
        .onTapGesture {
            browser.toggleSelection(item)
        }
        .contextMenu {
            Button(selected ? "Deselect" : "Select") { browser.toggleSelection(item) }
            Button("Remove from list") { browser.removeFromSession(item) }
        }
    }

    private func itemSubtitle(_ item: DriveItem) -> String {
        if item.downloadIsFolder {
            return "Folder · pick files inside to download"
        }
        if item.isGoogleNative {
            return item.displaySize + " · exports on download"
        }
        return item.displaySize
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let error = browser.lastError ?? downloads.lastError ?? auth.lastError {
                ErrorBanner(error: error)
            }

            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    StepLabel(title: "Destination")
                    if let destination {
                        Text(destination.url.path)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(DriveflowTheme.ink)
                            .lineLimit(1)
                            .help(destination.url.path)
                    } else {
                        Text("Pick a destination folder before downloading.")
                            .font(.system(size: 12))
                            .foregroundStyle(DriveflowTheme.inkMuted)
                    }
                }
                Spacer()
                Button(destination == nil ? "Choose folder…" : "Change folder…") {
                    if let url = DestinationPicker.chooseFolder() {
                        destination = try? DestinationPicker.inspect(url)
                    }
                }
                .buttonStyle(SoftFillButtonStyle())
                .font(.system(size: 13, weight: .semibold))

                Button {
                    Task { await startDownload() }
                } label: {
                    Text(downloadLabel)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                }
                .buttonStyle(PrimaryFillButtonStyle(enabled: canDownload))
                .disabled(!canDownload)
                .help(downloadHelp)
            }
        }
        .padding(20)
        .background(DriveflowTheme.paper)
    }

    private var canDownload: Bool {
        !browser.selectedItems.isEmpty && destination != nil
    }

    private var downloadLabel: String {
        let count = browser.selectedItems.count
        if count == 0 { return "Download" }
        if downloads.pendingItemCount > 0 {
            return count == 1 ? "Add to queue" : "Queue \(count)"
        }
        return "Download \(count)"
    }

    private var downloadHelp: String {
        if destination == nil {
            return "Choose a destination folder first."
        }
        if browser.selectedItems.isEmpty {
            return "Select one or more picked files to download."
        }
        if downloads.pendingItemCount > 0 {
            return "Add these items to the transfer queue."
        }
        return "Start downloading to \(destination?.url.path ?? "the chosen folder")."
    }

    private func startDownload() async {
        guard let destination else { return }
        let items = browser.selectedItems
        browser.clearSelection()
        await downloads.enqueue(items: items, destination: destination)
        if downloads.lastError == nil {
            section = .transfers
        }
    }
}
