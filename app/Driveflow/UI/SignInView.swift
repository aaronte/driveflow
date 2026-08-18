import SwiftUI

struct SignInView: View {
    @ObservedObject var auth: AuthSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var stage: Int = 0

    private let system = SystemCompatibility.current()

    var body: some View {
        ZStack {
            DriveflowTheme.canvas.ignoresSafeArea()

            // Soft paper glow — keeps type readable over the velocity field
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

            SpeedDashesView()
                .ignoresSafeArea()
                .opacity(stage >= 1 || reduceMotion ? 1 : 0)
                .scaleEffect(stage >= 1 || reduceMotion ? 1 : 0.96)
                .animation(
                    reduceMotion ? nil : .easeOut(duration: 0.5),
                    value: stage
                )

            VStack(spacing: 0) {
                Spacer(minLength: 56)

                Image("AppLogo")
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 96, height: 96)
                    .shadow(color: .black.opacity(0.12), radius: 18, y: 8)
                    .modifier(
                        StaggerSlide(
                            visible: stage >= 1,
                            reduceMotion: reduceMotion,
                            distance: 28
                        )
                    )

                Text("Driveflow")
                    .font(.system(size: 52, weight: .bold, design: .default))
                    .foregroundStyle(DriveflowTheme.ink)
                    .tracking(-1.4)
                    .multilineTextAlignment(.center)
                    .padding(.top, 18)
                    .modifier(
                        StaggerSlide(
                            visible: stage >= 1,
                            reduceMotion: reduceMotion,
                            distance: 28
                        )
                    )

                Text("Pick files in Google Drive, then download them at the speed of your connection.")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(DriveflowTheme.inkMuted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 14)
                    .modifier(
                        StaggerSlide(
                            visible: stage >= 2,
                            reduceMotion: reduceMotion,
                            distance: 22
                        )
                    )

                Button {
                    Task { await auth.signIn() }
                } label: {
                    HStack(spacing: 12) {
                        GoogleMark()
                            .frame(width: 18, height: 18)
                        Text(auth.isBusy ? "Opening Google Drive…" : "Sign in with Google")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .frame(width: 280)
                    .padding(.vertical, 14)
                }
                .buttonStyle(PrimaryFillButtonStyle(enabled: !auth.isBusy))
                .disabled(auth.isBusy)
                .padding(.top, 36)
                .modifier(
                    StaggerSlide(
                        visible: stage >= 3,
                        reduceMotion: reduceMotion,
                        distance: 16
                    )
                )

                if auth.isBusy {
                    Button("Cancel sign-in") {
                        auth.cancelSignIn()
                    }
                    .buttonStyle(GhostButtonStyle())
                    .font(.system(size: 13, weight: .medium))
                    .padding(.top, 12)
                    .transition(.opacity.combined(with: .offset(y: 4)))
                }

                if let error = auth.lastError {
                    ErrorBanner(error: error)
                        .frame(maxWidth: 360)
                        .padding(.top, 18)
                        .transition(.opacity.combined(with: .offset(y: 6)))
                }

                CompatibilityBadge(system: system)
                    .padding(.top, 28)
                    .modifier(
                        StaggerSlide(
                            visible: stage >= 4,
                            reduceMotion: reduceMotion,
                            distance: 12
                        )
                    )

                Spacer(minLength: 48)
            }
            .padding(.horizontal, 56)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            runEntrance()
        }
    }

    private func runEntrance() {
        if reduceMotion {
            stage = 4
            return
        }
        for i in 1...4 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04 + Double(i) * 0.12) {
                withAnimation(.spring(response: 0.48, dampingFraction: 1.0)) {
                    stage = i
                }
            }
        }
    }
}

// MARK: - Compatibility

/// Reads out the current Mac instead of stating requirements at it.
private struct CompatibilityBadge: View {
    let system: SystemCompatibility

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(system.isSupported ? DriveflowTheme.accent : DriveflowTheme.caution)
                .frame(width: 5, height: 5)

            Text(system.issue ?? system.summary)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(system.isSupported ? DriveflowTheme.inkFaint : DriveflowTheme.ink)
                .tracking(0.6)
                .textCase(.uppercase)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            system.isSupported
                ? "This Mac is supported: \(system.summary)"
                : "This Mac may not be supported: \(system.issue ?? "")"
        )
    }
}

// MARK: - Motion helpers

private struct StaggerSlide: ViewModifier {
    let visible: Bool
    let reduceMotion: Bool
    let distance: CGFloat

    func body(content: Content) -> some View {
        content
            .opacity(visible || reduceMotion ? 1 : 0)
            .offset(y: visible || reduceMotion ? 0 : distance * 0.35)
            .scaleEffect(visible || reduceMotion ? 1 : 0.985)
    }
}

// MARK: - Controls

/// Compact multicolor Google “G” — no third-party asset required.
private struct GoogleMark: View {
    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(
                    AngularGradient(
                        colors: [
                            Color(red: 0.26, green: 0.52, blue: 0.96),
                            Color(red: 0.22, green: 0.73, blue: 0.33),
                            Color(red: 0.98, green: 0.74, blue: 0.02),
                            Color(red: 0.92, green: 0.26, blue: 0.21),
                            Color(red: 0.26, green: 0.52, blue: 0.96),
                        ],
                        center: .center
                    ),
                    lineWidth: 2.2
                )
            Text("G")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(DriveflowTheme.onAccent)
                .offset(x: 0.3)
        }
    }
}

struct ErrorBanner: View {
    let error: AppError

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(error.localizedDescription)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(DriveflowTheme.ink)
            if let tip = error.recoverySuggestion {
                Text(tip)
                    .font(.system(size: 12))
                    .foregroundStyle(DriveflowTheme.inkMuted)
            }
            if case .licenseRequired = error {
                Link("Buy a license", destination: AppConfig.buyURL)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DriveflowTheme.accent)
                    .padding(.top, 2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            DriveflowTheme.paper.opacity(0.94),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .shadow(color: Color.black.opacity(0.04), radius: 12, x: 0, y: 4)
    }
}
