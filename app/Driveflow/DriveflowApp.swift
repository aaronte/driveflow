import SwiftUI
import AppKit

@main
struct DriveflowApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup("Driveflow") {
            ContentView()
                .environmentObject(appState.auth)
                .environmentObject(appState.browser)
                .environmentObject(appState.downloads)
                .preferredColorScheme(.light)
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    let auth: AuthSession
    let browser: DriveBrowserModel
    let downloads: DownloadController

    private var terminateObserver: NSObjectProtocol?

    init() {
        let auth = AuthSession()
        let drive = DriveClient(auth: auth)
        self.auth = auth
        self.browser = DriveBrowserModel(auth: auth, client: drive)
        let downloads = DownloadController(auth: auth, drive: drive)
        self.downloads = downloads
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            downloads.terminateEngineForShutdown()
        }
    }

    deinit {
        if let terminateObserver {
            NotificationCenter.default.removeObserver(terminateObserver)
        }
    }
}
