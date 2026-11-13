import AppKit
import SwiftUI

/// The small header every widget starts with: a label, and an optional button on the right.
private struct WidgetHeader: View {
    var title: String
    var symbol: String?
    var help = ""
    var action: (() -> Void)?

    var body: some View {
        HStack(spacing: 4) {
            Text(title).label().lineLimit(1)
            Spacer(minLength: 0)
            if let symbol, let action { IconButton(symbol: symbol, size: 18, help: help, action: action) }
        }
        .frame(height: 16)
    }
}

/// Words on a tile when there's nothing to show yet.
private struct Hint: View {
    var text: String
    var body: some View {
        Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.5))
            .multilineTextAlignment(.center).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private func ratioColor(_ r: Double, warn: Double = 0.75, critical: Double = 0.9) -> Color {
    r >= critical ? Color(red: 1, green: 0.36, blue: 0.36) : r >= warn ? Color(red: 1, green: 0.74, blue: 0.25) : Color(red: 0.42, green: 0.86, blue: 0.56)
}

// MARK: - Clipboard

struct ClipboardTile: View {
    @Environment(WidgetHub.self) private var hub
    @Environment(AppSettings.self) private var settings

    var body: some View {
        let clip = hub.clipboard
        Tile(padding: 10) {
            VStack(alignment: .leading, spacing: 4) {
                WidgetHeader(title: "CLIPBOARD", symbol: clip.items.isEmpty ? nil : "trash", help: "Clear the list") { clip.clear() }
                if clip.items.isEmpty {
                    Hint(text: "Copy some text and it shows up here")
                } else {
                    SnapScroll {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(clip.items) { item in
                                ClipRow(item: item, copied: clip.copied == item.id) { clip.copy(item) }
                            }
                        }
                    }
                }
            }
        }
        .help("Text you copied, newest first. Kept in memory only; password-manager copies are skipped. Click to copy again.")
    }
}

private struct ClipRow: View {
    var item: ClipboardModel.Item
    var copied: Bool
    var action: () -> Void
    private let _hover = State(initialValue: false)

    var body: some View {
        let hover = _hover.wrappedValue
        Button(action: action) {
            HStack(spacing: 6) {
                Text(item.text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces))
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.88)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
                if copied { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Color(red: 0.42, green: 0.86, blue: 0.56)) }
            }
            .padding(.horizontal, 7)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.white.opacity(hover ? 0.11 : 0.05)))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .onHover { h in _hover.wrappedValue = h }
        .help(String(item.text.prefix(400)))
    }
}

// MARK: - Scratchpad

struct ScratchpadTile: View {
    @Environment(AppSettings.self) private var settings
    @Environment(NotchState.self) private var state
    @Environment(\.snapshotMode) private var snapshot
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var s = settings
        Tile(padding: 10) {
            VStack(alignment: .leading, spacing: 4) {
                WidgetHeader(title: "SCRATCHPAD", symbol: s.scratchpad.isEmpty ? nil : "doc.on.doc", help: "Copy it all") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(settings.scratchpad, forType: .string)
                }
                ZStack(alignment: .topLeading) {
                    if snapshot {
                        Text(s.scratchpad.isEmpty ? "Jot something down…" : s.scratchpad)
                            .font(.system(size: 11.5)).foregroundStyle(.white.opacity(s.scratchpad.isEmpty ? 0.35 : 0.9))
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    } else {
                        TextEditor(text: $s.scratchpad)
                            .font(.system(size: 11.5))
                            .scrollContentBackground(.hidden)
                            .foregroundStyle(.white.opacity(0.92))
                            .focused($focused)
                            // The notch stays open while you type, like the Ask bar.
                            .onChange(of: focused) { _, f in state.pinned = f }
                            .onExitCommand { focused = false; state.collapseAction() }
                            .simultaneousGesture(TapGesture().onEnded { state.focusPromptAction() })
                            .padding(.horizontal, -5).padding(.vertical, -6)
                        if s.scratchpad.isEmpty {
                            Text("Jot something down…").font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.35)).allowsHitTesting(false)
                        }
                    }
                }
            }
        }
        .help("Saved as you type, on this Mac only")
    }
}

// MARK: - GitHub

struct GitHubTile: View {
    @Environment(WidgetHub.self) private var hub
    @Environment(AppSettings.self) private var settings

    var body: some View {
        let gh = hub.github
        Tile(padding: 10) {
            VStack(alignment: .leading, spacing: 4) {
                WidgetHeader(title: gh.state == .ready && gh.reviewCount > 0 ? "GITHUB · \(gh.reviewCount) TO REVIEW" : "GITHUB",
                             symbol: gh.state == .ready ? "arrow.clockwise" : nil, help: "Refresh") { gh.refresh(force: true) }
                switch gh.state {
                case .idle, .loading: Hint(text: "Loading…")
                case .missing:
                    VStack(spacing: 6) {
                        Hint(text: "Needs the GitHub command line")
                        Button("Get it") { NSWorkspace.shared.open(URL(string: "https://cli.github.com")!) }
                            .buttonStyle(PillButtonStyle(theme: settings.theme, prominent: true))
                    }
                case .signedOut:
                    VStack(spacing: 6) {
                        Hint(text: "Sign in once with gh auth login")
                        Button("Copy command") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("gh auth login", forType: .string)
                        }.buttonStyle(PillButtonStyle(theme: settings.theme, prominent: true))
                    }
                case .failed(let why): Hint(text: why)
                case .ready:
                    if gh.toReview.isEmpty && gh.mine.isEmpty {
                        Hint(text: "No open pull requests")
                    } else {
                        SnapScroll {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(gh.toReview) { PRRow(pr: $0, review: true) }
                                ForEach(gh.mine) { PRRow(pr: $0, review: false) }
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct PRRow: View {
    var pr: GitHubModel.PR
    var review: Bool
    private let _hover = State(initialValue: false)

    var body: some View {
        let hover = _hover.wrappedValue
        Button { NSWorkspace.shared.open(pr.url) } label: {
            HStack(spacing: 6) {
                if review {
                    Image(systemName: "eye.fill").font(.system(size: 8.5)).foregroundStyle(Color(red: 1, green: 0.74, blue: 0.25)).frame(width: 8)
                } else {
                    Circle().fill(color).frame(width: 7, height: 7)
                }
                Text(pr.title).font(.system(size: 11)).foregroundStyle(.white.opacity(0.88)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 7)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.white.opacity(hover ? 0.11 : 0.05)))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .onHover { h in _hover.wrappedValue = h }
        .help("\(pr.repo) #\(pr.number)\n\(pr.title)\n" + (review ? "Waiting for your review" : ciText))
    }

    private var color: Color {
        switch pr.ci {
        case .passing: Color(red: 0.42, green: 0.86, blue: 0.56)
        case .failing: Color(red: 1, green: 0.36, blue: 0.36)
        case .pending: Color(red: 1, green: 0.74, blue: 0.25)
        case nil: .white.opacity(0.3)
        }
    }
    private var ciText: String {
        switch pr.ci {
        case .passing: "Your pull request: checks passing"
        case .failing: "Your pull request: checks failing"
        case .pending: "Your pull request: checks running"
        case nil: "Your pull request: no checks"
        }
    }
}

// MARK: - System

struct SystemTile: View {
    @Environment(WidgetHub.self) private var hub
    @Environment(AppSettings.self) private var settings

    var body: some View {
        let s = hub.system
        let theme = settings.theme
        Tile(padding: 10) {
            VStack(alignment: .leading, spacing: 5) {
                WidgetHeader(title: "SYSTEM", symbol: nil, action: nil)
                if let b = s.batteryPercent {
                    meter(s.charging ? "bolt.fill" : "battery.75percent", "\(b)%", Double(b) / 100, color: s.charging ? theme.accent : ratioColor(1 - Double(b) / 100, warn: 0.8, critical: 0.9))
                }
                meter("cpu", "\(Int((s.cpu * 100).rounded()))%", s.cpu, color: ratioColor(s.cpu, warn: 0.7, critical: 0.9))
                meter("memorychip", "\(Int((s.memory * 100).rounded()))%", s.memory, color: s.pressure >= 4 ? ratioColor(1) : s.pressure >= 2 ? ratioColor(0.8) : ratioColor(0))
                Spacer(minLength: 0)
                HStack(spacing: 5) {
                    if let free = s.diskFreeGB {
                        Image(systemName: "internaldrive").font(.system(size: 9))
                        Text(free >= 1000 ? String(format: "%.1f TB free", free / 1000) : "\(Int(free)) GB free")
                    }
                    if let d = s.devices.first {
                        Image(systemName: "airpodspro").font(.system(size: 9)).padding(.leading, 2)
                        Text("\(d.percent)%")
                    }
                    Spacer(minLength: 0)
                }
                .font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                .help(s.devices.map { "\($0.name): \($0.percent)%" }.joined(separator: "\n"))
            }
        }
        .help("Battery, processor and memory load, free space, and the battery of connected Bluetooth devices")
    }

    private func meter(_ symbol: String, _ value: String, _ ratio: Double, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 10)).foregroundStyle(.white.opacity(0.6)).frame(width: 14)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.1))
                    Capsule().fill(color).frame(width: max(4, g.size.width * CGFloat(min(1, max(0, ratio)))))
                }
            }
            .frame(height: 6)
            Text(value).font(.system(size: 10.5, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white.opacity(0.85)).frame(width: 34, alignment: .trailing)
        }
        .frame(height: 20)
    }
}

// MARK: - Weather

struct WeatherTile: View {
    @Environment(WidgetHub.self) private var hub
    @Environment(AppSettings.self) private var settings

    var body: some View {
        let w = hub.weather
        Tile(padding: 10) {
            VStack(alignment: .leading, spacing: 4) {
                WidgetHeader(title: (w.place?.name ?? "WEATHER").uppercased(), symbol: w.place == nil ? nil : "pencil", help: "Change the city") { w.chooseCity() }
                switch w.state {
                case .needsCity:
                    VStack(spacing: 6) {
                        Hint(text: "Which city?")
                        Button("Set city") { w.chooseCity() }.buttonStyle(PillButtonStyle(theme: settings.theme, prominent: true))
                    }
                case .loading where w.now == nil: Hint(text: "Loading…")
                case .failed where w.now == nil:
                    VStack(spacing: 6) {
                        Hint(text: "Couldn't get the weather")
                        Button("Try again") { w.refresh(force: true) }.buttonStyle(PillButtonStyle(theme: settings.theme))
                    }
                default:
                    if let n = w.now {
                        let d = WeatherModel.describe(n.code, isDay: n.isDay)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .center, spacing: 8) {
                                Image(systemName: d.symbol).symbolRenderingMode(.multicolor).font(.system(size: 28))
                                Text("\(Int(n.temperature.rounded()))°").font(.system(size: 34, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                                Spacer(minLength: 0)
                            }
                            Text(d.text).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                            Spacer(minLength: 0)
                            HStack(spacing: 8) {
                                Text("H \(Int(n.high.rounded()))°  L \(Int(n.low.rounded()))°")
                                Text("Feels \(Int(n.feelsLike.rounded()))°")
                            }
                            .font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Volume and brightness

struct ControlsTile: View {
    @Environment(WidgetHub.self) private var hub
    @Environment(AppSettings.self) private var settings

    var body: some View {
        let c = hub.controls
        let theme = settings.theme
        Tile(padding: 10) {
            VStack(alignment: .leading, spacing: 8) {
                WidgetHeader(title: "SOUND & DISPLAY", symbol: nil, action: nil)
                if c.volume == nil && c.brightness == nil {
                    Hint(text: "No controls on this Mac")
                }
                if let v = c.volume {
                    LevelBar(symbol: c.muted || v == 0 ? "speaker.slash.fill" : v < 0.34 ? "speaker.wave.1.fill" : v < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill",
                             value: c.muted ? 0 : v, theme: theme, help: "Volume. Click the speaker to mute.",
                             iconAction: { c.setMuted(!c.muted) }) { c.setVolume($0, final: false) } done: { c.setVolume($0, final: true) }
                }
                if let b = c.brightness {
                    LevelBar(symbol: "sun.max.fill", value: b, theme: theme, help: "Display brightness",
                             iconAction: nil) { c.setBrightness($0, final: false) } done: { c.setBrightness($0, final: true) }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

/// A horizontal slider drawn in the app's own style: drag, or click anywhere on the bar.
struct LevelBar: View {
    var symbol: String
    var value: Float
    var theme: Theme
    var help: String
    var iconAction: (() -> Void)?
    var change: (Float) -> Void
    var done: (Float) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let iconAction {
                    Button(action: iconAction) { icon }.buttonStyle(PressScale())
                } else { icon }
            }
            .frame(width: 18)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.13)).frame(height: 8)
                    Capsule().fill(theme.gradient).frame(width: max(8, g.size.width * CGFloat(value)), height: 8)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { change(level(g, $0)) }
                    .onEnded { done(level(g, $0)) })
            }
            .frame(height: 24)
            Text("\(Int((value * 100).rounded()))").font(.system(size: 10.5, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white.opacity(0.7)).frame(width: 24, alignment: .trailing)
        }
        .help(help)
    }

    private var icon: some View {
        Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(.white.opacity(0.75))
    }

    private func level(_ g: GeometryProxy, _ v: DragGesture.Value) -> Float {
        Float(min(1, max(0, v.location.x / max(g.size.width, 1))))
    }
}
