import SwiftUI

/// Onboarding: show the service-account share email, wait for Shared-with-me items.
struct ShareSetupView: View {
    @ObservedObject var auth: AuthSession
    @ObservedObject var driveAccess: DriveAccessSession
    @ObservedObject var downloads: DownloadController

    var body: some View {
        ZStack {
            DriveflowTheme.canvas.ignoresSafeArea()

            RadialGradient(
                colors: [
                    DriveflowTheme.paper.opacity(0.96),
                    DriveflowTheme.paper.opacity(0.52),
                    DriveflowTheme.canvas.opacity(0),
                ],
                center: .center,
                startRadius: 20,
                endRadius: 540
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 40)

                Image("AppLogo")
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 72, height: 72)
                    .shadow(color: .black.opacity(0.12), radius: 18, y: 8)

                Text("Share a folder with Driveflow")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(DriveflowTheme.ink)
                    .tracking(-0.6)
                    .multilineTextAlignment(.center)
                    .padding(.top, 20)

                Text("Copy this address, then share the Drive folder you want as Viewer. Uncheck Notify people — service accounts have no inbox.")
                    .font(.system(size: 15))
                    .foregroundStyle(DriveflowTheme.inkMuted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)

                shareEmailBlock
                    .padding(.top, 28)

                instructions
                    .padding(.top, 24)

                if driveAccess.isWaitingForShare {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Waiting for a shared folder…")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(DriveflowTheme.inkMuted)
                    }
                    .padding(.top, 22)
                }

                if let error = driveAccess.lastError {
                    ErrorBanner(error: error)
                        .frame(maxWidth: 420)
                        .padding(.top, 18)
                }

                HStack(spacing: 12) {
                    Button("I’ve shared — check now") {
                        Task { await driveAccess.bindVisibleSharesAndEnter() }
                    }
                    .buttonStyle(PrimaryFillButtonStyle(enabled: !driveAccess.isBusy))
                    .disabled(driveAccess.isBusy || driveAccess.shareEmail == nil)

                    Button("Sign out") {
                        Task {
                            await downloads.clearEngineCredentials()
                            driveAccess.clear()
                            auth.signOut()
                        }
                    }
                    .buttonStyle(GhostButtonStyle())
                    .font(.system(size: 13, weight: .medium))
                }
                .padding(.top, 28)

                if let buyer = auth.userEmail {
                    Text("Signed in as \(buyer)")
                        .font(.system(size: 11))
                        .foregroundStyle(DriveflowTheme.inkFaint)
                        .padding(.top, 16)
                }

                Spacer(minLength: 40)
            }
            .padding(.horizontal, 56)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var shareEmailBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            StepLabel(title: "Share with")
            HStack(spacing: 12) {
                Text(driveAccess.shareEmail ?? "Loading share address…")
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundStyle(DriveflowTheme.ink)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button(driveAccess.didCopyShareEmail ? "Copied" : "Copy") {
                    driveAccess.copyShareEmailToPasteboard()
                }
                .buttonStyle(SoftFillButtonStyle())
                .font(.system(size: 13, weight: .semibold))
                .disabled(driveAccess.shareEmail == nil)
            }
            .padding(14)
            .background(
                DriveflowTheme.paper.opacity(0.94),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .shadow(color: Color.black.opacity(0.04), radius: 12, x: 0, y: 4)
        }
        .frame(maxWidth: 480)
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 10) {
            instructionRow(number: "1", text: "In Google Drive, open the folder → Share.")
            instructionRow(number: "2", text: "Paste the address above, role Viewer.")
            instructionRow(number: "3", text: "Uncheck “Notify people”, then Share.")
            Text("Workspace tip: if Share fails, an admin may block external sharing. For Shared Drives, add this address as a member.")
                .font(.system(size: 12))
                .foregroundStyle(DriveflowTheme.inkFaint)
                .padding(.top, 4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 480, alignment: .leading)
    }

    private func instructionRow(number: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(DriveflowTheme.accent)
                .frame(width: 16, alignment: .leading)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(DriveflowTheme.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
