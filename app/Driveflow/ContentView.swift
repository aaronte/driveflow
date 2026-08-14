import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var auth: AuthSession
    @EnvironmentObject private var browser: DriveBrowserModel
    @EnvironmentObject private var downloads: DownloadController

    var body: some View {
        Group {
            if auth.isSignedIn {
                BrowserView(auth: auth, browser: browser, downloads: downloads)
                    .transition(.opacity.combined(with: .offset(y: 8)))
            } else {
                SignInView(auth: auth)
                    .transition(.opacity.combined(with: .offset(y: 8)))
            }
        }
        .animation(.easeOut(duration: 0.22), value: auth.isSignedIn)
        .frame(minWidth: 960, minHeight: 640)
    }
}
