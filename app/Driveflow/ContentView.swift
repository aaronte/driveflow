import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var auth: AuthSession
    @EnvironmentObject private var driveAccess: DriveAccessSession
    @EnvironmentObject private var browser: DriveBrowserModel
    @EnvironmentObject private var downloads: DownloadController

    var body: some View {
        Group {
            if !auth.isSignedIn {
                SignInView(auth: auth)
                    .transition(.opacity.combined(with: .offset(y: 8)))
            } else if !driveAccess.isReady {
                ShareSetupView(auth: auth, driveAccess: driveAccess, downloads: downloads)
                    .transition(.opacity.combined(with: .offset(y: 8)))
            } else {
                BrowserView(
                    auth: auth,
                    driveAccess: driveAccess,
                    browser: browser,
                    downloads: downloads
                )
                .transition(.opacity.combined(with: .offset(y: 8)))
            }
        }
        .animation(.easeOut(duration: 0.22), value: auth.isSignedIn)
        .animation(.easeOut(duration: 0.22), value: driveAccess.isReady)
        .frame(minWidth: 960, minHeight: 640)
        .task(id: auth.isSignedIn) {
            await prepareDriveAccessIfNeeded()
        }
    }

    private func prepareDriveAccessIfNeeded() async {
        guard auth.isSignedIn, let email = auth.userEmail, !email.isEmpty else {
            driveAccess.clear()
            return
        }
        if let prefetched = auth.consumePendingShareSession() {
            await driveAccess.applyPrefetchedSession(prefetched, buyerEmail: email)
            if driveAccess.shareEmail != nil { return }
        }
        await driveAccess.bootstrap(buyerEmail: email)
    }
}
