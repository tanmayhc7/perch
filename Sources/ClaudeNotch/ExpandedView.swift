import AppKit
import LedgerKit
import SwiftUI

struct ExpandedView: View {
    @Environment(NotchState.self) private var state
    @Environment(ShelfModel.self) private var shelf
    @Environment(PromptModel.self) private var prompt

    var body: some View {
        let g = state.geometry
        VStack(spacing: 0) {
            HeaderRow().frame(height: g.height)
            Spacer().frame(height: 6)
            Group {
                if state.dropMode {
                    DropTargets()
                        .transition(.scale(scale: 0.96).combined(with: .opacity))
                } else if prompt.phase != .idle {
                    AnswerPanel()
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    TilesRow()
                        .transition(.opacity)
                }
            }
            .frame(height: NotchLayout.tileHeight)
            if !shelf.items.isEmpty {
                ShelfStrip()
                    .frame(height: NotchLayout.shelfHeight)
                    .padding(.top, NotchLayout.gap)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            PromptBar()
                .frame(height: NotchLayout.promptHeight)
                .padding(.top, NotchLayout.gap)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, NotchLayout.inset + NotchLayout.shoulder(expanded: true))
        .animation(.notch, value: state.dropMode)
        .animation(.notch, value: prompt.phase == .idle)
        .animation(.notch, value: shelf.items.count)
    }
}

// MARK: - Header

struct HeaderRow: View {
    @Environment(NotchState.self) private var state
    @Environment(ClaudeModel.self) private var claude
    @Environment(ShelfModel.self) private var shelf
    @Environment(AppSettings.self) private var settings

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 7) {
                Spark(theme: settings.theme, spinning: claude.stats.isResponding).frame(width: 12, height: 12)
                if claude.stats.isResponding {
                    Text("\(claude.stats.responding.count) responding")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
                } else {
                    Text("claude·notch").font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.6))
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 4)
            Spacer(minLength: state.geometry.width + 16)
            HStack(spacing: 4) {
                Spacer(minLength: 0)
                TimelineView(.everyMinute) { ctx in
                    Text(ctx.date, format: .dateTime.hour().minute())
                        .font(.system(size: 11, weight: .medium).monospacedDigit()).foregroundStyle(.white.opacity(0.55))
                        .padding(.trailing, 4)
                }
                SettingsMenu()
            }
        }
    }
}

struct SettingsMenu: View {
    @Environment(AppSettings.self) private var settings
    @Environment(NotchState.self) private var state
    @Environment(\.snapshotMode) private var snapshot

    var body: some View {
        @Bindable var s = settings
        Menu {
            Picker("Theme", selection: $s.theme) {
                ForEach(Theme.allCases) { Text($0.name).tag($0) }
            }
            Toggle("Open on hover", isOn: $s.hoverToExpand)
            Toggle("Alert when a session finishes", isOn: $s.finishAlerts)
            Toggle("Open at login", isOn: $s.launchAtLogin)
            Divider()
            Button("claude-notch on GitHub") { NSWorkspace.shared.open(URL(string: "https://github.com/tanmayhc7/claude-notch")!) }
            Button("Quit claude-notch") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .snapshotStandIn(snapshot) {
            Image(systemName: "ellipsis").font(.system(size: 12, weight: .bold)).foregroundStyle(.white.opacity(0.7)).frame(width: 26, height: 22)
        }
    }
}

// MARK: - Tiles

struct TilesRow: View {
    var body: some View {
        HStack(spacing: NotchLayout.gap) {
            ClaudeTile().frame(width: 300)
            MusicTile()
            VStack(spacing: NotchLayout.gap) {
                MeetingTile()
                TimerTile()
            }
            .frame(width: 162)
        }
    }
}

struct ClaudeTile: View {
    @Environment(ClaudeModel.self) private var claude
    @Environment(AppSettings.self) private var settings

    var body: some View {
        let s = claude.stats
        let theme = settings.theme
        Tile {
            if !claude.ledgerFound {
                VStack(alignment: .leading, spacing: 6) {
                    Text("CLAUDE CODE").label()
                    Text("No token-meter ledger yet").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    Text("Install the token-meter plugin in Claude Code to see live usage here.")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55)).fixedSize(horizontal: false, vertical: true)
                    Button("Get token-meter") { NSWorkspace.shared.open(URL(string: "https://github.com/tanmayhc7/claude-token-meter")!) }
                        .buttonStyle(PillButtonStyle(theme: theme, prominent: true))
                }
            } else {
                VStack(alignment: .leading, spacing: 9) {
                    HStack(alignment: .center, spacing: 14) {
                        gauge(s, theme: theme).frame(width: 78, height: 78)
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(alignment: .firstTextBaseline, spacing: 5) {
                                Text(TokenFormat.short(s.windowTokens))
                                    .font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
                                    .foregroundStyle(.white)
                                    .contentTransition(.numericText())
                                Text("last \(Int(s.windowHours))h").font(.system(size: 10.5, weight: .medium)).foregroundStyle(.white.opacity(0.5))
                            }
                            HStack(spacing: 10) {
                                stat("TODAY", TokenFormat.short(s.todayTokens))
                                stat("COST", String(format: "$%.2f", s.windowUSD))
                                stat("BURN", "\(TokenFormat.short(s.burnPerMinute))/m", warn: s.burnPerMinute >= 40_000)
                            }
                            Sparkline(values: s.burnHistory, theme: theme).frame(height: 16)
                        }
                    }
                    Spacer(minLength: 0)
                    sessions(s, theme: theme)
                }
            }
        }
    }

    @ViewBuilder private func gauge(_ s: ClaudeStats, theme: Theme) -> some View {
        ZStack {
            if let f = s.budgetUsedFraction {
                ProgressRing(progress: f, theme: theme, lineWidth: 7, warn: f >= 0.8)
                VStack(spacing: -1) {
                    Text("\(max(0, Int(((1 - f) * 100).rounded())))%")
                        .font(.system(size: 17, weight: .semibold, design: .rounded).monospacedDigit()).foregroundStyle(.white)
                    Text(f >= 1 ? "over" : "left").font(.system(size: 9.5, weight: .medium)).foregroundStyle(.white.opacity(0.5))
                }
            } else {
                // No budget: the ring shows the burn rate against token-meter's warning line.
                ProgressRing(progress: s.burnPerMinute / 40_000, theme: theme, lineWidth: 7, warn: s.burnPerMinute >= 40_000)
                VStack(spacing: -1) {
                    Text(TokenFormat.short(s.burnPerMinute))
                        .font(.system(size: 16, weight: .semibold, design: .rounded).monospacedDigit()).foregroundStyle(.white)
                    Text("tok/min").font(.system(size: 9.5, weight: .medium)).foregroundStyle(.white.opacity(0.5))
                }
            }
        }
        .help(s.budgetRemainingText.map { "All-sessions budget: \($0)" } ?? "No all-sessions budget. Set one in Claude Code with /token-budget all 5M")
    }

    private func stat(_ label: String, _ value: String, warn: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).label()
            Text(value).font(.system(size: 11.5, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(warn ? Color(red: 1, green: 0.74, blue: 0.25) : .white.opacity(0.88))
        }
    }

    @ViewBuilder private func sessions(_ s: ClaudeStats, theme: Theme) -> some View {
        HStack(spacing: 6) {
            if s.sessions.isEmpty {
                Text("No Claude Code sessions in the last \(Int(s.windowHours))h")
                    .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.45))
            }
            ForEach(s.sessions.prefix(2)) { a in
                HStack(spacing: 5) {
                    Circle()
                        .fill(a.state == .responding ? AnyShapeStyle(theme.gradient)
                              : AnyShapeStyle(a.state == .active ? Color.white.opacity(0.6) : Color.white.opacity(0.22)))
                        .frame(width: 6, height: 6)
                        .phaseAnimator(a.state == .responding ? [1.0, 0.35] : [1.0]) { v, o in v.opacity(o) } animation: { _ in .easeInOut(duration: 0.8) }
                    Text(a.project).lineLimit(1).truncationMode(.tail).frame(maxWidth: 92, alignment: .leading).fixedSize()
                        .font(.system(size: 10.5, weight: .medium)).foregroundStyle(.white.opacity(0.82))
                    Text(TokenFormat.short(a.windowTokens)).font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.4))
                }
                .padding(.horizontal, 7)
                .frame(height: 20)
                .background(Capsule().fill(.white.opacity(0.06)))
                .help("\(a.project): \(a.state == .responding ? "responding" : a.state == .active ? "active" : "idle")")
            }
            if s.sessions.count > 2 {
                Text("+\(s.sessions.count - 2)").font(.system(size: 10.5, weight: .medium)).foregroundStyle(.white.opacity(0.45))
            }
            Spacer(minLength: 0)
        }
    }
}

struct MusicTile: View {
    @Environment(SpotifyModel.self) private var spotify
    @Environment(AppSettings.self) private var settings

    var body: some View {
        let theme = settings.theme
        Tile(padding: 12) {
            if spotify.hasTrack {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        artwork.frame(width: 54, height: 54)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(spotify.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white).lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(spotify.artist).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        let pos = spotify.position(at: ctx.date)
                        VStack(spacing: 3) {
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(.white.opacity(0.12))
                                    Capsule().fill(theme.gradient)
                                        .frame(width: geo.size.width * (spotify.duration > 0 ? pos / spotify.duration : 0))
                                }
                            }
                            .frame(height: 3)
                            HStack {
                                Text(FocusTimer.format(pos))
                                Spacer()
                                Text(FocusTimer.format(spotify.duration))
                            }
                            .font(.system(size: 9, weight: .medium).monospacedDigit()).foregroundStyle(.white.opacity(0.4))
                        }
                    }
                    HStack(spacing: 14) {
                        Spacer(minLength: 0)
                        IconButton(symbol: "backward.fill", size: 26, help: "Previous") { spotify.previous() }
                        IconButton(symbol: spotify.playing ? "pause.fill" : "play.fill", size: 32, filled: true, theme: theme,
                                   help: spotify.playing ? "Pause" : "Play") { spotify.playPause() }
                        IconButton(symbol: "forward.fill", size: 26, help: "Next") { spotify.next() }
                        Spacer(minLength: 0)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("NOW PLAYING").label()
                    Spacer(minLength: 0)
                    Image(systemName: "waveform").font(.system(size: 22, weight: .light)).foregroundStyle(theme.gradient)
                    Text(statusText).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                    if spotify.installed, !spotify.running {
                        Button("Open Spotify") { spotify.openSpotify() }.buttonStyle(PillButtonStyle(theme: theme))
                    } else if spotify.permissionDenied {
                        Button("Open Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
                        }.buttonStyle(PillButtonStyle(theme: theme))
                    }
                }
            }
        }
        .background(
            // The artwork, blurred, glows through the tile.
            Color.clear.overlay {
                if let art = spotify.artwork, spotify.hasTrack {
                    Image(nsImage: art).resizable().scaledToFill().blur(radius: 30).opacity(0.38).saturation(1.4)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        )
    }

    private var statusText: String {
        if !spotify.installed { return "Spotify isn't installed" }
        if !spotify.running { return "Spotify is closed" }
        if spotify.permissionDenied { return "Allow claude-notch to control Spotify" }
        return "Nothing playing"
    }

    @ViewBuilder private var artwork: some View {
        if let art = spotify.artwork {
            Image(nsImage: art).resizable().scaledToFill()
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(color: .black.opacity(0.5), radius: 6, y: 3)
        } else {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.08))
                .overlay(Image(systemName: "music.note").foregroundStyle(.white.opacity(0.4)))
        }
    }
}

struct MeetingTile: View {
    @Environment(CalendarModel.self) private var calendar
    @Environment(AppSettings.self) private var settings

    var body: some View {
        Tile(padding: 10) {
            if !calendar.hasAccess {
                VStack(alignment: .leading, spacing: 5) {
                    Text("NEXT MEETING").label()
                    if calendar.access == .notDetermined {
                        Button("Show my calendar") { calendar.requestAccess() }.buttonStyle(PillButtonStyle(theme: settings.theme))
                    } else {
                        Button("Allow in Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                        }.buttonStyle(PillButtonStyle(theme: settings.theme))
                    }
                }
            } else if let m = calendar.next {
                TimelineView(.periodic(from: .now, by: 15)) { ctx in
                    HStack(alignment: .top, spacing: 8) {
                        Capsule().fill(Color(nsColor: m.color)).frame(width: 3)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(m.title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                            HStack(spacing: 6) {
                                Text(Self.when(m, now: ctx.date)).font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.55))
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                if let url = m.joinURL {
                                    Button("Join") { NSWorkspace.shared.open(url) }
                                        .buttonStyle(PillButtonStyle(theme: settings.theme, prominent: m.start.timeIntervalSince(ctx.date) < 600))
                                        .controlSize(.small)
                                }
                            }
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    Text("NEXT MEETING").label()
                    Text("Nothing in the next 24h").font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.6))
                }
            }
        }
    }

    static func when(_ m: CalendarModel.Meeting, now: Date) -> String {
        let until = m.start.timeIntervalSince(now)
        if until <= 0 { return "Now · \(max(1, Int(m.end.timeIntervalSince(now) / 60)))m left" }
        if until < 3600 { return "in \(max(1, Int(until / 60))) min" }
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(m.start) ? "'at' h:mm a" : "'tomorrow' h:mm a"
        return f.string(from: m.start)
    }
}

struct TimerTile: View {
    @Environment(FocusTimer.self) private var timer
    @Environment(AppSettings.self) private var settings

    var body: some View {
        let theme = settings.theme
        Tile(padding: 10) {
            if timer.phase == .idle {
                VStack(alignment: .leading, spacing: 6) {
                    Text("FOCUS").label()
                    HStack(spacing: 5) {
                        ForEach([(25.0, "Focus"), (50.0, "Deep work"), (5.0, "Break")], id: \.0) { m, label in
                            Button("\(Int(m))m") { timer.start(minutes: m, label: label) }
                                .buttonStyle(PillButtonStyle(theme: theme))
                                .help("\(label): \(Int(m)) minutes")
                        }
                    }
                }
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    HStack(spacing: 8) {
                        ProgressRing(progress: timer.progress(at: ctx.date), theme: theme, lineWidth: 3.5).frame(width: 30, height: 30)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(FocusTimer.format(timer.remaining(at: ctx.date)))
                                .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit()).foregroundStyle(.white)
                            Text(timer.phase == .paused ? "Paused" : timer.label).font(.system(size: 9.5, weight: .medium)).foregroundStyle(.white.opacity(0.5))
                        }
                        Spacer(minLength: 0)
                        IconButton(symbol: timer.phase == .paused ? "play.fill" : "pause.fill", size: 22) { timer.toggle() }
                        IconButton(symbol: "xmark", size: 22) { timer.stop() }
                    }
                }
            }
        }
    }
}

// MARK: - Prompt

struct PromptBar: View {
    @Environment(PromptModel.self) private var prompt
    @Environment(AppSettings.self) private var settings
    @Environment(NotchState.self) private var state
    @FocusState private var focused: Bool
    @Environment(\.snapshotMode) private var snapshot

    var body: some View {
        @Bindable var p = prompt
        let theme = settings.theme
        HStack(spacing: 10) {
            Spark(theme: theme, spinning: prompt.phase == .running).frame(width: 14, height: 14)
            if snapshot {
                Text("Ask Claude anything…").font(.system(size: 13)).foregroundStyle(.white.opacity(0.35))
                Spacer()
            } else {
                TextField("Ask Claude anything…", text: $p.text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                    .focused($focused)
                    .onSubmit { prompt.send(model: settings.promptModel) }
                    .onTapGesture { state.focusPromptAction(); focused = true }
            }
            Menu {
                ForEach(PromptModel.models, id: \.id) { m in
                    Button { settings.promptModel = m.id } label: {
                        if settings.promptModel == m.id { Label(m.name, systemImage: "checkmark") } else { Text(m.name) }
                    }
                }
            } label: {
                Text(PromptModel.models.first { $0.id == settings.promptModel }?.name ?? "Haiku")
                    .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.white.opacity(0.65))
                    .padding(.horizontal, 8).frame(height: 22)
                    .background(Capsule().fill(.white.opacity(0.08)))
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("Model for questions from the notch")
            .snapshotStandIn(snapshot) { modelChip }
            if prompt.phase == .running {
                IconButton(symbol: "stop.fill", size: 26, help: "Stop") { prompt.cancel() }
            } else {
                IconButton(symbol: "arrow.up", size: 26, weight: .bold, filled: !prompt.text.isEmpty, theme: theme, help: "Ask (Return)") {
                    prompt.send(model: settings.promptModel)
                }
            }
        }
        .padding(.leading, 14).padding(.trailing, 7)
        .background(Capsule().fill(.white.opacity(focused ? 0.1 : 0.06)))
        .overlay(Capsule().strokeBorder(focused ? AnyShapeStyle(theme.gradient.opacity(0.7)) : AnyShapeStyle(.white.opacity(0.1)), lineWidth: focused ? 1 : 0.75))
        .animation(.easeOut(duration: 0.2), value: focused)
        .onChange(of: focused) { _, f in
            state.pinned = f
            if f { state.focusPromptAction() }
        }
    }
}

extension PromptBar {
    var modelChip: some View {
        Text(PromptModel.models.first { $0.id == settings.promptModel }?.name ?? "Haiku")
            .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.white.opacity(0.65))
            .padding(.horizontal, 8).frame(height: 22)
            .background(Capsule().fill(.white.opacity(0.08)))
    }
}

struct AnswerPanel: View {
    @Environment(PromptModel.self) private var prompt
    @Environment(AppSettings.self) private var settings

    var body: some View {
        let theme = settings.theme
        Tile(padding: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "person.fill").font(.system(size: 9)).foregroundStyle(.white.opacity(0.4))
                    Text(prompt.asked).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                    Spacer(minLength: 0)
                    if let c = prompt.costUSD {
                        Text(String(format: "$%.4f", c)).font(.system(size: 10).monospacedDigit()).foregroundStyle(.white.opacity(0.35))
                    }
                    if !prompt.answer.isEmpty {
                        IconButton(symbol: "doc.on.doc", size: 22, help: "Copy answer") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(prompt.answer, forType: .string)
                        }
                    }
                    IconButton(symbol: "xmark", size: 22, help: "Close") { prompt.reset() }
                }
                SnapScroll {
                    Group {
                        switch prompt.phase {
                        case .failed(let msg):
                            Text(msg).foregroundStyle(Color(red: 1, green: 0.5, blue: 0.5))
                        case .running where prompt.answer.isEmpty:
                            Text("Thinking…").foregroundStyle(theme.gradient)
                                .phaseAnimator([0.4, 1.0]) { v, o in v.opacity(o) } animation: { _ in .easeInOut(duration: 0.7) }
                        default:
                            Text(LocalizedStringKey(prompt.answer)).foregroundStyle(.white.opacity(0.92)).textSelection(.enabled)
                        }
                    }
                    .font(.system(size: 12.5))
                    .lineSpacing(2.5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

// MARK: - Drop zone and shelf

struct DropTargets: View {
    @Environment(ShelfModel.self) private var shelf
    @Environment(NotchState.self) private var state
    @Environment(AppSettings.self) private var settings
    // `State` written out: the command-line SDK has no @State macro plugin.
    private let _overAirDrop = State(initialValue: false)
    private var overAirDrop: Bool { get { _overAirDrop.wrappedValue } nonmutating set { _overAirDrop.wrappedValue = newValue } }
    // `State` written out: the command-line SDK has no @State macro plugin.
    private let _overShelf = State(initialValue: false)
    private var overShelf: Bool { get { _overShelf.wrappedValue } nonmutating set { _overShelf.wrappedValue = newValue } }

    @Environment(\.snapshotMode) private var snapshot

    var body: some View {
        HStack(spacing: NotchLayout.gap) {
            if snapshot {
                target(symbol: "dot.radiowaves.left.and.right", title: "AirDrop", subtitle: "Send to a nearby device", hot: false)
                target(symbol: "tray.and.arrow.down.fill", title: "Shelf", subtitle: "Hold here, drag out later", hot: true)
            } else {
                target(symbol: "dot.radiowaves.left.and.right", title: "AirDrop", subtitle: "Send to a nearby device", hot: overAirDrop)
                    .onDrop(of: [.fileURL], isTargeted: _overAirDrop.projectedValue) { providers in
                        ShelfModel.loadURLs(providers) { urls in
                            state.dropMode = false
                            ShelfModel.airDrop(urls)
                        }
                        return true
                    }
                target(symbol: "tray.and.arrow.down.fill", title: "Shelf", subtitle: "Hold here, drag out later", hot: overShelf)
                    .onDrop(of: [.fileURL], isTargeted: _overShelf.projectedValue) { providers in
                        ShelfModel.loadURLs(providers) { urls in
                            shelf.add(urls)
                            state.dropMode = false
                        }
                        return true
                    }
            }
        }
    }

    private func target(symbol: String, title: String, subtitle: String, hot: Bool) -> some View {
        let theme = settings.theme
        return VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .medium))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(hot ? AnyShapeStyle(theme.gradient) : AnyShapeStyle(.white.opacity(0.75)))
                .symbolEffect(.bounce, value: hot)
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
            Text(subtitle).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(hot ? AnyShapeStyle(theme.gradient.opacity(0.16)) : AnyShapeStyle(.white.opacity(0.04)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(hot ? AnyShapeStyle(theme.gradient) : AnyShapeStyle(.white.opacity(0.18)),
                              style: StrokeStyle(lineWidth: hot ? 1.5 : 1, dash: hot ? [] : [5, 4]))
        )
        .scaleEffect(hot ? 1.02 : 1)
        .animation(.notch, value: hot)
    }
}

struct ShelfStrip: View {
    @Environment(ShelfModel.self) private var shelf
    @Environment(AppSettings.self) private var settings

    var body: some View {
        Tile(padding: 8) {
            HStack(spacing: 8) {
                SnapScroll(axis: .horizontal) {
                    HStack(spacing: 6) {
                        ForEach(shelf.items) { item in
                            ShelfItemView(item: item)
                        }
                    }
                }
                VStack(spacing: 4) {
                    Button("AirDrop all") { ShelfModel.airDrop(shelf.items.map(\.url)) }.buttonStyle(PillButtonStyle(theme: settings.theme))
                    Button("Clear") { shelf.clear() }.buttonStyle(PillButtonStyle(theme: settings.theme))
                }
                .fixedSize()
            }
        }
    }
}

struct ShelfItemView: View {
    let item: ShelfModel.Item
    @Environment(ShelfModel.self) private var shelf
    // `State` written out: the command-line SDK has no @State macro plugin.
    private let _hover = State(initialValue: false)
    private var hover: Bool { get { _hover.wrappedValue } nonmutating set { _hover.wrappedValue = newValue } }

    var body: some View {
        VStack(spacing: 2) {
            Image(nsImage: item.icon).resizable().frame(width: 28, height: 28)
            Text(item.name).font(.system(size: 9.5, weight: .medium)).foregroundStyle(.white.opacity(0.8))
                .lineLimit(1).truncationMode(.middle).frame(width: 66)
        }
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(hover ? 0.1 : 0)))
        .overlay(alignment: .topTrailing) {
            if hover {
                Button { shelf.remove(item) } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(.white.opacity(0.8))
                }
                .buttonStyle(.plain)
                .offset(x: 2, y: -2)
            }
        }
        .onHover { hover = $0 }
        .modifier(ShelfItemActions(item: item))
    }
}

/// Drag out and the context menu (left out of snapshots, which can't draw them).
private struct ShelfItemActions: ViewModifier {
    let item: ShelfModel.Item
    @Environment(ShelfModel.self) private var shelf
    @Environment(\.snapshotMode) private var snapshot

    func body(content: Content) -> some View {
        if snapshot {
            content
        } else {
            content
                .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
                .help(item.url.path)
                .contextMenu {
                    Button("Open") { NSWorkspace.shared.open(item.url) }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                    Button("AirDrop") { ShelfModel.airDrop([item.url]) }
                    Divider()
                    Button("Remove from shelf") { shelf.remove(item) }
                }
        }
    }
}
