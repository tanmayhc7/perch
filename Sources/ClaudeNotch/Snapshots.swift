import AppKit
import LedgerKit
import SwiftUI

/// Renders the notch in its main states from sample data, for the README and design reviews.
/// `ClaudeNotch --snapshot <dir>`; needs no permissions and touches no real data.
@MainActor
enum Snapshots {
    static func render(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for theme in Theme.allCases {
            shot(dir, "expanded-\(theme.rawValue)", theme: theme) { env in env.state.mode = .expanded }
        }
        shot(dir, "collapsed-responding", theme: .ember, height: 120) { env in
            env.timer.start(minutes: 25, label: "Focus")
        }
        shot(dir, "toast-budget", theme: .ember, height: 130) { env in
            env.state.toast = Toast(symbol: "gauge.with.dots.needle.67percent", tint: .warning, title: "80% of your Claude budget used",
                                    subtitle: "4M in 5h · 1M left")
        }
        shot(dir, "drag-hint", theme: .ember, height: 130) { env in env.state.dragHint = true }
        shot(dir, "drop", theme: .ember) { env in
            env.state.mode = .expanded
            env.state.dropMode = true
        }
        shot(dir, "answer", theme: .ember) { env in
            env.state.mode = .expanded
            env.prompt.asked = "What's the zsh one-liner to find files over 100MB?"
            env.prompt.answer = "Use `find` with a size filter:\n\n`find . -type f -size +100M -exec ls -lh {} +`\n\nAdd `2>/dev/null` to hide permission errors."
            env.prompt.phase = .done
            env.prompt.costUSD = 0.0012
        }
        shot(dir, "shelf", theme: .ember) { env in
            env.state.mode = .expanded
            env.shelf.add([URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"),
                           URL(fileURLWithPath: "/Library/Desktop Pictures"),
                           URL(fileURLWithPath: "/etc/hosts")])
        }
        print("Wrote snapshots to \(dir.path)")
    }

    private static func sampleEnv(theme: Theme) -> AppEnvironment {
        let settings = AppSettings(persist: false)
        settings.theme = theme
        let state = NotchState(geometry: NotchGeometry(width: 185, height: 32, hasNotch: true, midX: 0, top: 0))
        let env = AppEnvironment(state: state, settings: settings, claude: ClaudeModel(), spotify: SpotifyModel(),
                                 shelf: ShelfModel(), calendar: CalendarModel(), timer: FocusTimer(), prompt: PromptModel())
        let now = Date()
        func req(_ minsAgo: Double, _ counted: Double) -> LedgerRequest {
            LedgerRequest(ts: now.addingTimeInterval(-minsAgo * 60), input: 0, output: 0, cacheRead: 0, cacheWrite: 0, usd: counted / 220_000, counted: counted)
        }
        let a = LedgerSession(id: "a", cwd: "/Users/me/code/token-meter", updatedAt: now, streaming: 3_400,
                              reqs: (0..<40).map { req(Double($0) * 0.7, Double(12_000 + ($0 * 3_700) % 21_000)) })
        let b = LedgerSession(id: "b", cwd: "/Users/me/code/claude-notch", updatedAt: now.addingTimeInterval(-30), streaming: 0,
                              reqs: (0..<30).map { req(Double($0) * 4 + 3, 26_000) })
        let c = LedgerSession(id: "c", cwd: "/Users/me/code/website", updatedAt: now.addingTimeInterval(-3600), streaming: 0,
                              reqs: (0..<20).map { req(Double($0) * 6 + 120, 30_000) })
        env.claude.loaded = true
        env.spotify.loaded = true
        env.claude.stats = ClaudeStats.compute(sessions: [a, b, c], budget: LedgerBudget(tokens: 5_000_000), now: now)
        env.spotify.installed = true
        env.spotify.running = true
        env.spotify.playing = true
        env.spotify.title = "Midnight Static"
        env.spotify.artist = "The Paper Satellites"
        env.spotify.duration = 214
        env.spotify.positionAtRead = 83
        env.spotify.positionAt = now
        env.spotify.artwork = sampleArtwork()
        env.calendar.access = .fullAccess
        env.calendar.next = .init(title: "Design review", start: now.addingTimeInterval(7 * 60 + 20), end: now.addingTimeInterval(40 * 60),
                                  joinURL: URL(string: "https://meet.google.com/abc-defg-hij"), color: .systemPurple)
        return env
    }

    private static func shot(_ dir: URL, _ name: String, theme: Theme, height: CGFloat = 390, setup: (AppEnvironment) -> Void) {
        let env = sampleEnv(theme: theme)
        setup(env)
        let width: CGFloat = 900
        let view = ZStack(alignment: .top) {
            Wallpaper(theme: theme)
            MenuBarStrip(height: env.state.geometry.height)
            NotchRootView().notchEnvironment(env).environment(\.snapshotMode, true).frame(width: 820, height: height - 4)
        }
        .frame(width: width, height: height)
        let r = ImageRenderer(content: view)
        r.scale = 2
        guard let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { print("render failed: \(name)"); return }
        try? png.write(to: dir.appendingPathComponent("\(name).png"))
    }

    static func sampleArtwork() -> NSImage {
        let size = NSSize(width: 300, height: 300)
        return NSImage(size: size, flipped: false) { r in
            NSGradient(colors: [NSColor(red: 0.98, green: 0.42, blue: 0.30, alpha: 1), NSColor(red: 0.30, green: 0.18, blue: 0.62, alpha: 1)])?
                .draw(in: r, angle: -55)
            NSColor.white.withAlphaComponent(0.85).setFill()
            NSBezierPath(ovalIn: NSRect(x: 95, y: 95, width: 110, height: 110)).fill()
            NSColor(red: 0.18, green: 0.10, blue: 0.30, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: 135, y: 135, width: 30, height: 30)).fill()
            return true
        }
    }
}

private struct Wallpaper: View {
    var theme: Theme
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.10, green: 0.12, blue: 0.20), Color(red: 0.24, green: 0.20, blue: 0.32)],
                           startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [theme.accent2.opacity(0.35), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 600)
            RadialGradient(colors: [Color.blue.opacity(0.25), .clear], center: .bottomLeading, startRadius: 0, endRadius: 500)
        }
    }
}

private struct MenuBarStrip: View {
    var height: CGFloat
    var body: some View {
        HStack(spacing: 18) {
            Image(systemName: "apple.logo").font(.system(size: 13))
            Text("Finder").fontWeight(.bold)
            Text("File"); Text("Edit"); Text("View")
            Spacer()
            Image(systemName: "wifi"); Image(systemName: "battery.75percent")
            Text("Sat 9:41")
        }
        .font(.system(size: 13))
        .foregroundStyle(.white.opacity(0.9))
        .padding(.horizontal, 16)
        .frame(height: height)
        .background(.black.opacity(0.18))
    }
}

/// The app icon: the spark on a black squircle with an ember halo. `ClaudeNotch --icon <dir.iconset>`.
@MainActor
enum IconRenderer {
    static func render(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (pt, scales) in [(16, [1, 2]), (32, [1, 2]), (128, [1, 2]), (256, [1, 2]), (512, [1, 2])] {
            for s in scales {
                let view = AppIcon().frame(width: 1024, height: 1024)
                let r = ImageRenderer(content: view)
                r.scale = CGFloat(pt * s) / 1024
                guard let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else { continue }
                let name = s == 1 ? "icon_\(pt)x\(pt).png" : "icon_\(pt)x\(pt)@2x.png"
                try? png.write(to: dir.appendingPathComponent(name))
            }
        }
    }
}

private struct AppIcon: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 230, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.13), .black], startPoint: .top, endPoint: .bottom))
                .frame(width: 824, height: 824)
            // A notch along the top edge.
            NotchShape(shoulder: 22, bottom: 46)
                .fill(.black)
                .frame(width: 380, height: 92)
                .offset(y: -366)
            SparkShape()
                .fill(Theme.ember.gradient)
                .frame(width: 380, height: 380)
                .blur(radius: 60)
                .opacity(0.7)
            SparkShape()
                .fill(LinearGradient(colors: [Color(red: 1, green: 0.66, blue: 0.42), Theme.ember.accent, Theme.ember.accent2],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 400, height: 400)
            RoundedRectangle(cornerRadius: 230, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 4)
                .frame(width: 824, height: 824)
        }
        .frame(width: 1024, height: 1024)
    }
}
