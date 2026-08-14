import SwiftUI

enum DriveflowTheme {
    /// Warm cream stage — closer to the sign-in mock (#F5F0E6 family)
    static let canvas = Color(red: 0.961, green: 0.941, blue: 0.902) // #F5F0E6
    static let paper = Color(red: 0.988, green: 0.976, blue: 0.953) // #FCF9F3
    static let stone = Color(red: 0.906, green: 0.871, blue: 0.824) // #E7DED2
    static let ink = Color(red: 0.110, green: 0.102, blue: 0.094) // #1C1A18 — crisper wordmark
    static let inkMuted = Color(red: 0.400, green: 0.373, blue: 0.345) // #665F58
    static let inkFaint = Color(red: 0.604, green: 0.565, blue: 0.518) // #9A9084
    /// One accent — deep teal for CTA + rare craft marks
    static let accent = Color(red: 0.000, green: 0.420, blue: 0.384) // #006B62
    static let onAccent = Color(red: 0.996, green: 0.980, blue: 0.961) // #FEFAF5
    /// Reserved for genuine problem states only — muted ochre, not alarm red
    static let caution = Color(red: 0.686, green: 0.451, blue: 0.145) // #AF7325
}

struct StepLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(DriveflowTheme.inkMuted)
            .textCase(.uppercase)
            .tracking(0.6)
    }
}

// MARK: - Interaction styles

private enum DriveflowMotion {
    static let micro = Animation.easeOut(duration: 0.12)
}

/// Primary teal CTA — hover lifts tone, press settles to 0.96.
struct PrimaryFillButtonStyle: ButtonStyle {
    var enabled: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        PrimaryFillBody(configuration: configuration, enabled: enabled)
    }

    private struct PrimaryFillBody: View {
        let configuration: ButtonStyle.Configuration
        let enabled: Bool
        @State private var hovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(DriveflowTheme.onAccent)
                .background(
                    fill,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .scaleEffect(configuration.isPressed && enabled ? 0.96 : 1)
                .opacity(enabled ? 1 : 0.55)
                .onHover { hovering = $0 }
                .animation(DriveflowMotion.micro, value: hovering)
                .animation(DriveflowMotion.micro, value: configuration.isPressed)
        }

        private var fill: Color {
            guard enabled else { return DriveflowTheme.inkFaint }
            if configuration.isPressed { return DriveflowTheme.accent.opacity(0.88) }
            if hovering { return DriveflowTheme.accent.opacity(0.92) }
            return DriveflowTheme.accent
        }
    }
}

/// Secondary stone chip — hover deepens, press settles.
struct SoftFillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SoftFillBody(configuration: configuration)
    }

    private struct SoftFillBody: View {
        let configuration: ButtonStyle.Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(DriveflowTheme.ink)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    fill,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .scaleEffect(configuration.isPressed ? 0.96 : 1)
                .onHover { hovering = $0 }
                .animation(DriveflowMotion.micro, value: hovering)
                .animation(DriveflowMotion.micro, value: configuration.isPressed)
        }

        private var fill: Color {
            if configuration.isPressed { return DriveflowTheme.stone.opacity(0.95) }
            if hovering { return DriveflowTheme.stone }
            return DriveflowTheme.stone.opacity(0.72)
        }
    }
}

/// Quiet text/link control — hover ink (or accent), press dims.
struct GhostButtonStyle: ButtonStyle {
    var prominent: Bool = false
    var accent: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        GhostBody(configuration: configuration, prominent: prominent, accent: accent)
    }

    private struct GhostBody: View {
        let configuration: ButtonStyle.Configuration
        let prominent: Bool
        let accent: Bool
        @State private var hovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(color)
                .opacity(configuration.isPressed ? 0.7 : 1)
                .onHover { hovering = $0 }
                .animation(DriveflowMotion.micro, value: hovering)
                .animation(DriveflowMotion.micro, value: configuration.isPressed)
        }

        private var color: Color {
            if accent {
                return hovering || configuration.isPressed
                    ? DriveflowTheme.accent.opacity(0.8)
                    : DriveflowTheme.accent
            }
            if hovering || prominent { return DriveflowTheme.ink }
            return DriveflowTheme.inkMuted
        }
    }
}

/// Sidebar / nav row — hover wash, selected stone fill, press settle.
struct NavRowButtonStyle: ButtonStyle {
    var isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        NavRowBody(configuration: configuration, isSelected: isSelected)
    }

    private struct NavRowBody: View {
        let configuration: ButtonStyle.Configuration
        let isSelected: Bool
        @State private var hovering = false

        var body: some View {
            configuration.label
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
                .padding(.horizontal, 10)
                .background(
                    fill,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .scaleEffect(configuration.isPressed ? 0.985 : 1)
                .onHover { hovering = $0 }
                .animation(DriveflowMotion.micro, value: hovering)
                .animation(DriveflowMotion.micro, value: configuration.isPressed)
        }

        private var fill: Color {
            if isSelected { return DriveflowTheme.stone.opacity(0.85) }
            if configuration.isPressed { return DriveflowTheme.stone.opacity(0.55) }
            if hovering { return DriveflowTheme.stone.opacity(0.4) }
            return .clear
        }
    }
}

/// Compact top-level workspace tab with selected and hover feedback.
struct WorkspaceTabButtonStyle: ButtonStyle {
    var isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        WorkspaceTabBody(configuration: configuration, isSelected: isSelected)
    }

    private struct WorkspaceTabBody: View {
        let configuration: ButtonStyle.Configuration
        let isSelected: Bool
        @State private var hovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(isSelected ? DriveflowTheme.ink : DriveflowTheme.inkMuted)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    fill,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .onHover { hovering = $0 }
                .animation(DriveflowMotion.micro, value: hovering)
                .animation(DriveflowMotion.micro, value: configuration.isPressed)
        }

        private var fill: Color {
            if isSelected { return DriveflowTheme.stone.opacity(0.72) }
            if configuration.isPressed { return DriveflowTheme.stone.opacity(0.5) }
            if hovering { return DriveflowTheme.stone.opacity(0.34) }
            return .clear
        }
    }
}

/// List row hover wash for selectable Drive items.
struct HoverableRow: ViewModifier {
    var isSelected: Bool = false
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                fill,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .onHover { hovering = $0 }
            .animation(DriveflowMotion.micro, value: hovering)
            .animation(DriveflowMotion.micro, value: isSelected)
    }

    private var fill: Color {
        if isSelected { return DriveflowTheme.accent.opacity(0.12) }
        if hovering { return DriveflowTheme.stone.opacity(0.5) }
        return .clear
    }
}

extension View {
    func hoverableRow(isSelected: Bool = false) -> some View {
        modifier(HoverableRow(isSelected: isSelected))
    }
}
