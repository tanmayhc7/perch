import LedgerKit
import SwiftUI

extension Animation {
    /// The notch's spring: fast, with a small overshoot so it reads as "opening".
    static let notch = Animation.spring(response: 0.3, dampingFraction: 0.74, blendDuration: 0.03)
}

struct NotchRootView: View {
    @Environment(NotchState.self) private var state
    @Environment(AppSettings.self) private var settings
    @Environment(ClaudeModel.self) private var claude
    @Environment(FocusTimer.self) private var timer
    @Environment(CalendarModel.self) private var calendar
    @Environment(ShelfModel.self) private var shelf

    var body: some View {
        let size = NotchLayout.shapeSize(state: state, claude: claude, timer: timer, calendar: calendar, shelf: shelf)
        let expanded = state.isExpanded
        let shape = NotchShape(shoulder: NotchLayout.shoulder(expanded: expanded),
                               bottom: expanded ? 28 : (state.toast != nil || state.dragHint ? 20 : 10))
        ZStack(alignment: .top) {
            ResponseGlow(active: claude.stats.isResponding, shape: shape, theme: settings.theme, expanded: expanded)
                .frame(width: size.width, height: size.height)

            ZStack(alignment: .top) {
                NotchBackground(expanded: expanded, theme: settings.theme, notchHeight: state.geometry.height)
                if expanded {
                    ExpandedView()
                        .transition(.asymmetric(
                            // Each section animates itself in (see `Entrance`), so the container only fades.
                            insertion: .opacity.animation(.easeOut(duration: 0.08)),
                            removal: .opacity.animation(.easeOut(duration: 0.1))))
                } else {
                    CollapsedView()
                        .transition(.opacity.animation(.easeInOut(duration: 0.18)))
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(shape)
            .overlay(
                shape.stroke(LinearGradient(colors: [.white.opacity(0), .white.opacity(expanded ? 0.13 : 0.0)],
                                            startPoint: .top, endPoint: .bottom), lineWidth: 1)
            )
            .shadow(color: .black.opacity(expanded ? 0.55 : 0), radius: 24, y: 12)
            .contentShape(shape)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.notch, value: size)
        .animation(.notch, value: expanded)
        .environment(\.colorScheme, .dark)
    }
}

/// Pure black where the hardware notch is, easing into a smoky glass lit by the theme.
struct NotchBackground: View {
    var expanded: Bool
    var theme: Theme
    var notchHeight: CGFloat

    var body: some View {
        ZStack {
            Color.black
            if expanded {
                RadialGradient(colors: [theme.accent.opacity(0.20), .clear], center: UnitPoint(x: 0.05, y: 1.05),
                               startRadius: 0, endRadius: 380)
                RadialGradient(colors: [theme.accent2.opacity(0.13), .clear], center: UnitPoint(x: 0.98, y: 0.35),
                               startRadius: 0, endRadius: 300)
                LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black.opacity(0.0), location: 0.45)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(maxHeight: notchHeight * 3, alignment: .top)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        }
    }
}

/// A soft halo around the notch that breathes while a Claude Code session is responding,
/// plus a light that sweeps along the bottom edge.
struct ResponseGlow: View {
    var active: Bool
    var shape: NotchShape
    var theme: Theme
    var expanded: Bool

    var body: some View {
        if active {
            ZStack(alignment: .bottom) {
                shape.fill(theme.gradient)
                    .blur(radius: expanded ? 22 : 10)
                    .phaseAnimator([0.35, 0.9]) { v, phase in v.opacity(phase) } animation: { _ in .easeInOut(duration: 1.5) }
                    .padding(.horizontal, expanded ? 8 : 2)
            }
            .offset(y: expanded ? 4 : 2)
            .transition(.opacity.animation(.easeInOut(duration: 0.6)))
            .allowsHitTesting(false)
        }
    }
}

// MARK: - Collapsed

struct CollapsedView: View {
    @Environment(NotchState.self) private var state
    @Environment(ClaudeModel.self) private var claude
    @Environment(FocusTimer.self) private var timer
    @Environment(CalendarModel.self) private var calendar
    @Environment(AppSettings.self) private var settings

    var body: some View {
        let g = state.geometry
        let ears = NotchLayout.hasEars(claude: claude, timer: timer, calendar: calendar)
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if ears {
                    leftEar.frame(width: NotchLayout.ear, alignment: .leading).padding(.leading, 14)
                    Spacer(minLength: g.width)
                    rightEar.frame(width: NotchLayout.ear, alignment: .trailing).padding(.trailing, 14)
                } else {
                    Spacer()
                }
            }
            .frame(height: g.height)
            if state.dragHint {
                DragHintView(theme: settings.theme)
                    .transition(.move(edge: .top).combined(with: .opacity))
            } else if let t = state.toast {
                ToastView(toast: t, theme: settings.theme)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { state.expandAction() }
    }

    @ViewBuilder private var leftEar: some View {
        if claude.stats.isResponding {
            HStack(spacing: 5) {
                Spark(theme: settings.theme, spinning: true).frame(width: 13, height: 13)
                Text(TokenFormat.short(claude.stats.streamingTokens))
                    .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.9))
                    .contentTransition(.numericText())
            }
        }
    }

    @ViewBuilder private var rightEar: some View {
        if timer.phase != .idle {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                HStack(spacing: 5) {
                    Text(FocusTimer.format(timer.remaining(at: ctx.date)))
                        .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white.opacity(timer.phase == .paused ? 0.45 : 0.9))
                    ProgressRing(progress: timer.progress(at: ctx.date), theme: settings.theme, lineWidth: 2.2)
                        .frame(width: 13, height: 13)
                }
            }
        } else if let m = NotchLayout.meetingSoon(calendar) {
            TimelineView(.periodic(from: .now, by: 15)) { ctx in
                HStack(spacing: 5) {
                    Text(m.start > ctx.date ? "\(max(1, Int(m.start.timeIntervalSince(ctx.date) / 60)))m" : "now")
                        .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.9))
                    Image(systemName: "video.fill").font(.system(size: 10)).foregroundStyle(Color(nsColor: m.color))
                }
            }
        }
    }
}

struct ToastView: View {
    var toast: Toast
    var theme: Theme

    private var tint: Color {
        switch toast.tint {
        case .accent: theme.accent
        case .warning: Color(red: 1, green: 0.74, blue: 0.25)
        case .danger: Color(red: 1, green: 0.36, blue: 0.36)
        case .calm: Color(red: 0.42, green: 0.86, blue: 0.56)
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: toast.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(Circle().fill(tint.opacity(0.16)))
            VStack(alignment: .leading, spacing: 1) {
                Text(toast.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                if let s = toast.subtitle {
                    Text(s).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if let title = toast.actionTitle, let action = toast.action {
                Button(title) { action() }
                    .buttonStyle(PillButtonStyle(theme: theme, prominent: true))
            }
        }
        .padding(.horizontal, 22)
        .frame(height: 50)
    }
}

/// Slides out of the closed notch while files are being dragged anywhere on screen.
struct DragHintView: View {
    var theme: Theme

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.up")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(theme.gradient)
                .phaseAnimator([0.0, -4.0]) { v, y in v.offset(y: y) } animation: { _ in .easeInOut(duration: 0.45) }
                .frame(width: 28, height: 28)
                .background(Circle().fill(theme.accent.opacity(0.16)))
            VStack(alignment: .leading, spacing: 1) {
                Text("Drop files on the notch").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white)
                Text("AirDrop them, or keep them on the shelf").font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .frame(height: 50)
    }
}
