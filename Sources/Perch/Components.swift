import SwiftUI

/// A four-point spark, the app's mark. Spins slowly while Claude is responding.
struct Spark: View {
    var theme: Theme
    var spinning = false

    var body: some View {
        SparkShape()
            .fill(theme.gradient)
            .shadow(color: theme.accent.opacity(0.6), radius: spinning ? 4 : 0)
            .phaseAnimator(spinning ? [0.0, 360.0] : [0.0]) { v, a in v.rotationEffect(.degrees(a)) } animation: { _ in
                .linear(duration: 2.4)
            }
    }
}

struct SparkShape: Shape {
    func path(in r: CGRect) -> Path {
        let c = CGPoint(x: r.midX, y: r.midY)
        let R = min(r.width, r.height) / 2
        let k = R * 0.18
        var p = Path()
        let pts: [CGPoint] = [CGPoint(x: c.x, y: c.y - R), CGPoint(x: c.x + R, y: c.y), CGPoint(x: c.x, y: c.y + R), CGPoint(x: c.x - R, y: c.y)]
        p.move(to: pts[0])
        for i in 0..<4 {
            let a = pts[i], b = pts[(i + 1) % 4]
            p.addQuadCurve(to: b, control: CGPoint(x: c.x + (a.x - c.x + b.x - c.x) * (k / R), y: c.y + (a.y - c.y + b.y - c.y) * (k / R)))
        }
        p.closeSubpath()
        return p
    }
}

struct ProgressRing: View {
    var progress: Double
    var theme: Theme
    var lineWidth: CGFloat = 6
    var warn = false

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.09), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, progress)))
                .stroke(AngularGradient(colors: warn ? [Color(red: 1, green: 0.74, blue: 0.25), Color(red: 1, green: 0.36, blue: 0.36)]
                                                       : [theme.accent, theme.accent2, theme.accent],
                                        center: .center),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: (warn ? Color.red : theme.accent).opacity(0.45), radius: lineWidth * 0.8)
        }
        .animation(.notch, value: progress)
    }
}

/// The rounded glass card everything in the expanded notch sits on.
struct Tile<Content: View>: View {
    var padding: CGFloat = 12
    @ViewBuilder var content: Content
    @Environment(AppSettings.self) private var settings

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        content
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background {
                if settings.theme == .glass {
                    // A darker pane of glass on the clear glass, so tiles, text and buttons stand out from the
                    // bright, see-through edges around them.
                    GlassFill(shape: shape).overlay(shape.fill(.black.opacity(0.32)))
                } else {
                    shape.fill(LinearGradient(colors: [.white.opacity(0.075), .white.opacity(0.035)], startPoint: .top, endPoint: .bottom))
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.16), .white.opacity(0.04)], startPoint: .top, endPoint: .bottom),
                                  lineWidth: 0.75)
            )
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

struct PillButtonStyle: ButtonStyle {
    var theme: Theme
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(prominent ? .black : .white.opacity(0.9))
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Capsule().fill(prominent ? AnyShapeStyle(theme.gradient) : AnyShapeStyle(.white.opacity(0.1))))
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// A round icon button that lifts on hover.
struct IconButton: View {
    var symbol: String
    var size: CGFloat = 26
    var weight: Font.Weight = .semibold
    var filled = false
    var theme: Theme = .ember
    var help: String = ""
    var action: () -> Void
    // `State` written out: the command-line SDK has no @State macro plugin.
    private let _hover = State(initialValue: false)
    private var hover: Bool { get { _hover.wrappedValue } nonmutating set { _hover.wrappedValue = newValue } }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.42, weight: weight))
                .foregroundStyle(filled ? AnyShapeStyle(Color.black) : AnyShapeStyle(Color.white.opacity(hover ? 1 : 0.78)))
                .frame(width: size, height: size)
                .background(Circle().fill(filled ? AnyShapeStyle(theme.gradient) : AnyShapeStyle(Color.white.opacity(hover ? 0.14 : 0.0))))
                .scaleEffect(hover ? 1.06 : 1)
        }
        .buttonStyle(PressScale())
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
        .help(help)
    }
}

struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// Tiny bar chart of tokens per minute.
struct Sparkline: View {
    var values: [Double]
    var theme: Theme

    var body: some View {
        GeometryReader { geo in
            let maxV = max(values.max() ?? 0, 1)
            let w = geo.size.width / CGFloat(max(values.count, 1))
            HStack(alignment: .bottom, spacing: 0) {
                ForEach(values.indices, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(values[i] > 0 ? AnyShapeStyle(theme.gradient) : AnyShapeStyle(.white.opacity(0.1)))
                        .frame(width: max(1, w - 1.5), height: max(1.5, geo.size.height * values[i] / maxV))
                        .frame(width: w, alignment: .center)
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
    }
}

extension Text {
    func label() -> some View {
        self.font(.system(size: 9.5, weight: .semibold)).tracking(0.8).foregroundStyle(.white.opacity(0.42))
    }
}

private struct SnapshotModeKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// True while rendering README screenshots: AppKit-backed controls don't draw in ImageRenderer.
    var snapshotMode: Bool {
        get { self[SnapshotModeKey.self] }
        set { self[SnapshotModeKey.self] = newValue }
    }
}

extension View {
    @ViewBuilder func snapshotStandIn<V: View>(_ on: Bool, @ViewBuilder _ standIn: () -> V) -> some View {
        if on { standIn() } else { self }
    }
}

/// A ScrollView, except in snapshots, where ImageRenderer can't draw one.
struct SnapScroll<Content: View>: View {
    var axis: Axis.Set = .vertical
    @ViewBuilder var content: Content
    @Environment(\.snapshotMode) private var snapshot

    var body: some View {
        if snapshot {
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).clipped()
        } else {
            ScrollView(axis) { content }.scrollIndicators(.never)
        }
    }
}
