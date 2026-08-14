import SwiftUI

/// Full-field speed dashes — layered L→R velocity field.
/// Far/mid/near depths + rare teal packets = “fast transfer” without neon noise.
struct SpeedDashesView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var startedAt = Date.now

    private let dashes: [Dash] = Dash.field

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height

            TimelineView(
                .animation(
                    minimumInterval: reduceMotion ? 1.0 / 4.0 : 1.0 / 48.0,
                    paused: reduceMotion
                )
            ) { timeline in
                let t = reduceMotion ? 0.0 : timeline.date.timeIntervalSinceReferenceDate
                let elapsed = reduceMotion ? 1.0 : timeline.date.timeIntervalSince(startedAt)

                Canvas { context, size in
                    for dash in dashes {
                        let y = height * dash.y
                        let pulse = 0.5 + 0.5 * sin(t * (1.4 + dash.speed) + dash.phase * 6.28)
                        let length = width * dash.lengthFraction * (0.9 + pulse * 0.1)
                        let surge = sin(t * 0.8 + dash.phase * 6.28) * 0.016
                        let cycle = (t * dash.speed + surge + dash.phase)
                            .truncatingRemainder(dividingBy: 1.0)
                        let entrance = min(1, max(0, (elapsed - dash.introDelay) / 0.32))
                        // Overrun so dashes enter/exit cleanly off-stage
                        let travel = width + length * 2.4
                        let x = -length * 1.2 + cycle * travel

                        var path = Path()
                        path.move(to: CGPoint(x: x, y: y))
                        path.addLine(to: CGPoint(x: x + length, y: y))

                        let liveOpacity = dash.opacity * (0.72 + pulse * 0.28) * entrance
                        let color: Color = dash.isPacket
                            ? DriveflowTheme.accent.opacity(liveOpacity)
                            : DriveflowTheme.inkMuted.opacity(liveOpacity)

                        // Soft leading tip — reads as motion blur / packet head
                        if dash.isPacket {
                            let head = CGRect(
                                x: x + length - 3.5,
                                y: y - 2.2,
                                width: 4.4,
                                height: 4.4
                            )
                            context.fill(
                                Path(ellipseIn: head),
                                with: .color(DriveflowTheme.accent.opacity(min(0.6, liveOpacity + 0.16)))
                            )
                        }

                        context.stroke(
                            path,
                            with: .color(color),
                            style: StrokeStyle(
                                lineWidth: dash.lineWidth,
                                lineCap: .round
                            )
                        )
                    }
                }
                .frame(width: width, height: height)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct Dash: Sendable {
    let y: Double
    let lengthFraction: Double
    let opacity: Double
    let lineWidth: Double
    let speed: Double
    let phase: Double
    let introDelay: Double
    let isPacket: Bool

    /// Three depth bands + sparse teal packets.
    static let field: [Dash] = {
        var result: [Dash] = []
        let phi = 0.6180339887

        // Far: slow, faint atmosphere
        for i in 0..<28 {
            result.append(make(index: i, band: .far, phi: phi, packet: false))
        }
        // Mid: primary ink streaks
        for i in 0..<34 {
            result.append(make(index: i + 40, band: .mid, phi: phi, packet: false))
        }
        // Near: faster, denser — speed of connection
        for i in 0..<18 {
            result.append(make(index: i + 90, band: .near, phi: phi, packet: false))
        }
        // Teal packets — rare data units in the stream
        for i in 0..<6 {
            result.append(make(index: i * 17 + 3, band: .packet, phi: phi, packet: true))
        }
        return result
    }()

    private enum Band {
        case far, mid, near, packet
    }

    private static func make(index: Int, band: Band, phi: Double, packet: Bool) -> Dash {
        let n = Double(index)
        let yBase = (0.05 + ((n * phi).truncatingRemainder(dividingBy: 1.0)) * 0.90)
        // Slight lane clustering so flow feels purposeful
        let lane = (n * 0.13).truncatingRemainder(dividingBy: 0.08)
        let y = min(0.96, max(0.04, yBase + lane * 0.15 - 0.01))

        let lengthFraction: Double
        let opacity: Double
        let lineWidth: Double
        let speed: Double

        switch band {
        case .far:
            lengthFraction = 0.04 + Double(index % 3) * 0.02
            opacity = 0.035 + Double(index % 2) * 0.025
            lineWidth = 0.65
            speed = 0.18 + Double(index % 5) * 0.04
        case .mid:
            lengthFraction = 0.06 + Double(index % 4) * 0.025
            opacity = 0.07 + Double(index % 3) * 0.04
            lineWidth = index % 3 == 0 ? 1.35 : 0.9
            speed = 0.44 + Double(index % 6) * 0.07
        case .near:
            lengthFraction = 0.09 + Double(index % 3) * 0.04
            opacity = 0.14 + Double(index % 3) * 0.055
            lineWidth = index % 2 == 0 ? 1.6 : 1.15
            speed = 0.78 + Double(index % 5) * 0.12
        case .packet:
            lengthFraction = 0.12 + Double(index % 2) * 0.05
            opacity = 0.38
            lineWidth = 1.8
            speed = 1.08 + Double(index % 3) * 0.16
        }

        let phase = (n * phi * 2.7).truncatingRemainder(dividingBy: 1.0)
        let introDelay = Double(index % 9) * 0.045
        return Dash(
            y: y,
            lengthFraction: lengthFraction,
            opacity: opacity,
            lineWidth: lineWidth,
            speed: speed,
            phase: phase,
            introDelay: introDelay,
            isPacket: packet
        )
    }
}
