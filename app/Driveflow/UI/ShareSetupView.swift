import SwiftUI

struct ShareSetupView: View {
    @ObservedObject var auth: AuthSession
    @ObservedObject var driveAccess: DriveAccessSession
    @ObservedObject var downloads: DownloadController

    var body: some View {
        ZStack {
            DriveflowTheme.canvas.ignoresSafeArea()

            VStack(spacing: 0) {
                GeometryReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            if driveAccess.canDismissAddFolder {
                                HStack {
                                    Button {
                                        driveAccess.dismissAddFolder()
                                    } label: {
                                        Label("Back to folders", systemImage: "chevron.left")
                                            .font(.system(size: 13, weight: .medium))
                                    }
                                    .buttonStyle(GhostButtonStyle())
                                    Spacer()
                                }
                                .frame(maxWidth: 560)
                                .padding(.bottom, 8)
                            }

                            Image("AppLogo")
                                .resizable()
                                .interpolation(.high)
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 64, height: 64)
                                .shadow(color: .black.opacity(0.12), radius: 18, y: 8)

                            Text("Add a folder")
                                .font(.system(size: 32, weight: .bold))
                                .foregroundStyle(DriveflowTheme.ink)
                                .tracking(-0.6)
                                .padding(.top, 18)

                            Text("Two steps: tell Driveflow which folder, then share it with your private Driveflow address.")
                                .font(.system(size: 15))
                                .foregroundStyle(DriveflowTheme.inkMuted)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 440)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, 10)

                            VStack(spacing: 14) {
                                pasteCard
                                shareCard
                            }
                            .frame(maxWidth: 560)
                            .padding(.top, 28)

                            if let error = driveAccess.lastError, !driveAccess.onboarding.isWaiting {
                                ErrorBanner(error: error)
                                    .frame(maxWidth: 560)
                                    .padding(.top, 16)
                            }

                            footnotes
                                .padding(.top, 22)
                        }
                        .padding(.horizontal, 40)
                        .padding(.vertical, 28)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: proxy.size.height)
                    }
                }

                signedInBar
            }
        }
    }

    private var linkBinding: Binding<String> {
        Binding(
            get: { driveAccess.onboarding.linkText },
            set: { driveAccess.updateFolderLink($0) }
        )
    }

    private var pasteCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            stepHeader(number: 1, title: "Paste your Google Drive folder link")

            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .font(.system(size: 13))
                    .foregroundStyle(DriveflowTheme.inkFaint)
                TextField("https://drive.google.com/drive/folders/…", text: linkBinding)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(DriveflowTheme.ink)
                    .accessibilityLabel("Google Drive folder link")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                DriveflowTheme.paper,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(linkBorder, lineWidth: 1)
            )

            linkStatus
        }
        .padding(16)
        .driveflowCard()
    }

    @ViewBuilder
    private var linkStatus: some View {
        let onboarding = driveAccess.onboarding
        if onboarding.isWaiting {
            Text("Waiting for access to your folder")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(DriveflowTheme.inkMuted)
        } else if onboarding.rejection == .notAFolder {
            statusLine(
                systemImage: "exclamationmark.circle.fill",
                text: "That link isn’t a folder. Paste the folder’s link instead.",
                color: DriveflowTheme.caution
            )
        } else {
            switch onboarding.status {
            case .empty:
                EmptyView()
            case .recognized:
                statusLine(
                    systemImage: "checkmark.circle.fill",
                    text: "Folder link recognized",
                    color: DriveflowTheme.accent
                )
            case .fileLink:
                statusLine(
                    systemImage: "exclamationmark.circle.fill",
                    text: "That looks like a file link. Paste the folder’s link instead.",
                    color: DriveflowTheme.caution
                )
            case .unrecognized:
                statusLine(
                    systemImage: "exclamationmark.circle.fill",
                    text: "Paste a Google Drive folder link, like https://drive.google.com/drive/folders/…",
                    color: DriveflowTheme.caution
                )
            }
        }
    }

    private func statusLine(systemImage: String, text: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 13))
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(color)
    }

    private var linkBorder: Color {
        let onboarding = driveAccess.onboarding
        if onboarding.isWaiting { return DriveflowTheme.stone }
        if onboarding.rejection == .notAFolder { return DriveflowTheme.caution.opacity(0.7) }
        switch onboarding.status {
        case .recognized:
            return DriveflowTheme.accent.opacity(0.65)
        case .fileLink, .unrecognized:
            return DriveflowTheme.caution.opacity(0.7)
        case .empty:
            return DriveflowTheme.stone
        }
    }

    private var shareCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            stepHeader(number: 2, title: "Share it with Driveflow")

            HStack(spacing: 8) {
                Text(driveAccess.shareEmail ?? "Loading share address…")
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(DriveflowTheme.ink)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    driveAccess.copyShareEmailToPasteboard()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: driveAccess.onboarding.didCopy ? "checkmark.circle.fill" : "doc.on.doc")
                            .font(.system(size: 12, weight: .semibold))
                        Text(driveAccess.onboarding.didCopy ? "Copied" : "Copy")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(
                        driveAccess.onboarding.didCopy ? DriveflowTheme.accent : DriveflowTheme.ink
                    )
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(
                        DriveflowTheme.paper,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(DriveflowTheme.stone, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .disabled(driveAccess.shareEmail == nil)
                .accessibilityLabel(
                    driveAccess.onboarding.didCopy ? "Copied share email" : "Copy share email"
                )
            }
            .padding(.leading, 14)
            .padding(.trailing, 6)
            .padding(.vertical, 6)
            .background(
                DriveflowTheme.stone.opacity(0.45),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 8) {
                    openSharingButton
                    shareHints
                }
                VStack(alignment: .leading, spacing: 8) {
                    openSharingButton
                    shareHints
                }
            }

            if driveAccess.onboarding.isWaiting {
                waitingPanel
            }
        }
        .padding(16)
        .driveflowCard()
    }

    private var openSharingButton: some View {
        Button {
            driveAccess.openSharingInDrive()
        } label: {
            HStack(spacing: 8) {
                DriveMark()
                Text("Open sharing in Drive")
                    .font(.system(size: 14, weight: .semibold))
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11, weight: .bold))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .buttonStyle(PrimaryFillButtonStyle(enabled: canOpenSharing))
        .disabled(!canOpenSharing)
        .accessibilityLabel("Open sharing in Drive")
    }

    private var shareHints: some View {
        HStack(spacing: 8) {
            hintChip {
                Text("Role: ") + Text("Viewer").fontWeight(.semibold)
            }
            hintChip {
                Text("Uncheck “Notify people”")
            }
        }
    }

    private var canOpenSharing: Bool {
        driveAccess.onboarding.recognizedFolderID != nil && !driveAccess.onboarding.isWaiting
    }

    private var waitingPanel: some View {
        HStack(alignment: .center, spacing: 12) {
            ProgressView()
                .controlSize(.small)
                .tint(DriveflowTheme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Waiting for access…")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DriveflowTheme.ink)
                Text("Checking every few seconds. This window updates on its own.")
                    .font(.system(size: 12))
                    .foregroundStyle(DriveflowTheme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Cancel") {
                driveAccess.cancelWaitingForAccess()
            }
            .buttonStyle(GhostButtonStyle())
            .font(.system(size: 13, weight: .medium))
        }
        .padding(12)
        .background(
            DriveflowTheme.accent.opacity(0.10),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .accessibilityElement(children: .combine)
    }

    private var footnotes: some View {
        VStack(spacing: 10) {
            Text("Driveflow can only see folders you share with this address. Remove access anytime from the folder’s Share menu in Drive.")
                .foregroundStyle(DriveflowTheme.inkMuted)
            Text("Using Google Workspace? If sharing is blocked, your admin may restrict sharing outside your organization.")
                .foregroundStyle(DriveflowTheme.inkFaint)
        }
        .font(.system(size: 12))
        .multilineTextAlignment(.center)
        .frame(maxWidth: 520)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var signedInBar: some View {
        HStack(spacing: 6) {
            if let buyer = auth.userEmail {
                Text("Signed in as \(buyer)")
                Text("·")
                    .accessibilityHidden(true)
            }
            Button("Sign out") {
                Task {
                    await downloads.clearEngineCredentials()
                    driveAccess.clear()
                    auth.signOut()
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(DriveflowTheme.inkFaint)
        }
        .font(.system(size: 12))
        .foregroundStyle(DriveflowTheme.inkFaint)
        .padding(.bottom, 18)
        .padding(.top, 8)
    }

    private func stepHeader(number: Int, title: String) -> some View {
        HStack(spacing: 10) {
            Text("\(number)")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(DriveflowTheme.onAccent)
                .frame(width: 22, height: 22)
                .background(DriveflowTheme.accent, in: Circle())
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(DriveflowTheme.ink)
        }
    }

    private func hintChip<Label: View>(@ViewBuilder label: () -> Label) -> some View {
        label()
            .font(.system(size: 12))
            .foregroundStyle(DriveflowTheme.inkMuted)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                DriveflowTheme.stone.opacity(0.55),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
    }
}

private struct DriveMark: View {
    var body: some View {
        Canvas { context, size in
            let width = size.width
            let height = size.height
            var yellow = Path()
            yellow.move(to: CGPoint(x: width * 0.50, y: 0))
            yellow.addLine(to: CGPoint(x: width * 0.78, y: height * 0.42))
            yellow.addLine(to: CGPoint(x: width * 0.22, y: height * 0.42))
            yellow.closeSubpath()
            context.fill(yellow, with: .color(Color(red: 0.98, green: 0.74, blue: 0.02)))

            var green = Path()
            green.move(to: CGPoint(x: width * 0.16, y: height * 0.50))
            green.addLine(to: CGPoint(x: width * 0.42, y: height * 0.50))
            green.addLine(to: CGPoint(x: width * 0.28, y: height))
            green.addLine(to: CGPoint(x: width * 0.02, y: height))
            green.closeSubpath()
            context.fill(green, with: .color(Color(red: 0.13, green: 0.59, blue: 0.33)))

            var blue = Path()
            blue.move(to: CGPoint(x: width * 0.58, y: height * 0.50))
            blue.addLine(to: CGPoint(x: width * 0.98, y: height))
            blue.addLine(to: CGPoint(x: width * 0.72, y: height))
            blue.addLine(to: CGPoint(x: width * 0.44, y: height * 0.50))
            blue.closeSubpath()
            context.fill(blue, with: .color(Color(red: 0.26, green: 0.52, blue: 0.96)))
        }
        .frame(width: 16, height: 14)
        .accessibilityHidden(true)
    }
}

private extension View {
    func driveflowCard() -> some View {
        return background(
            DriveflowTheme.paper,
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(DriveflowTheme.stone.opacity(0.9), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.04), radius: 16, y: 6)
    }
}
