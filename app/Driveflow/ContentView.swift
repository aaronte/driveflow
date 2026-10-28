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
            } else if driveAccess.showsShareSetup {
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
        .animation(.easeOut(duration: 0.22), value: driveAccess.showsShareSetup)
        .frame(minWidth: 960, minHeight: 640)
        .task(id: auth.isSignedIn) {
            await prepareDriveAccessIfNeeded()
        }
        .onChange(of: driveAccess.authenticationFailure?.id) { _, failureID in
            guard failureID != nil, let failure = driveAccess.authenticationFailure else { return }
            returnToSignIn(because: failure)
        }
    }

    private func returnToSignIn(because failure: AppError) {
        Task {
            await downloads.clearEngineCredentials()
            browser.resetForSignOut()
            driveAccess.clear()
            auth.signOut()
            auth.lastError = failure
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
