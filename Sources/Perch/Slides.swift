import AppKit
import SwiftUI

/// A full-width page of the open notch. Home is the fixed tile row; Board is the one the person
/// builds from widgets (see `Widget`).
enum Slide: String, CaseIterable, Identifiable {
    case home, board
    var id: String { rawValue }
    var name: String { self == .home ? "Home" : "Your slide" }
}

/// A tile the person can put on the second slide. To add one: a case here, its name, and its view in
/// `BoardSlide`. It then shows up in the menu and sits beside the others.
enum Widget: String, CaseIterable, Identifiable {
    case calendar, links
    var id: String { rawValue }
    var name: String {
        switch self {
        case .calendar: "Today's calendar"
        case .links: "Quick links"
        }
    }
}

/// A shortcut on the Quick links tile.
struct QuickLink: Codable, Equatable, Identifiable {
    var title: String
    var url: String
    var id: String { title + "|" + url }

    static let limit = 4
    static let starters = [QuickLink(title: "Claude", url: "https://claude.ai"),
                           QuickLink(title: "GitHub", url: "https://github.com"),
                           QuickLink(title: "Gmail", url: "https://mail.google.com")]

    /// The address to open: "github.com" is taken as https://github.com.
    var destination: URL? {
        let t = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        return URL(string: t.contains("://") || t.hasPrefix("mailto:") ? t : "https://" + t)
    }
    var host: String {
        guard let d = destination else { return url }
        let h = d.host() ?? d.absoluteString
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }
}

extension AppSettings {
    /// The widgets on the second slide, in their fixed order.
    var widgets: [Widget] { Widget.allCases.filter { !disabledWidgets.contains($0.rawValue) } }
    /// Home, then the second slide while it has at least one widget.
    var slides: [Slide] { widgets.isEmpty ? [.home] : [.home, .board] }

    func isOn(_ w: Widget) -> Bool { !disabledWidgets.contains(w.rawValue) }

    func set(_ w: Widget, on: Bool) {
        if on { disabledWidgets.remove(w.rawValue) } else { disabledWidgets.insert(w.rawValue) }
    }

    /// A small form: a name and an address for each of the four slots. Empty rows are dropped.
    func editQuickLinks() {
        let alert = NSAlert()
        alert.messageText = "Quick links"
        alert.informativeText = "Up to \(QuickLink.limit) links on your slide. Leave a row empty to remove it."
        let rowH: CGFloat = 30
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: rowH * CGFloat(QuickLink.limit)))
        var fields: [(NSTextField, NSTextField)] = []
        for i in 0..<QuickLink.limit {
            let y = box.frame.height - rowH * CGFloat(i + 1) + 3
            let name = NSTextField(frame: NSRect(x: 0, y: y, width: 130, height: 24))
            let url = NSTextField(frame: NSRect(x: 138, y: y, width: 282, height: 24))
            name.placeholderString = "Name"
            url.placeholderString = "https://…"
            if i < quickLinks.count { name.stringValue = quickLinks[i].title; url.stringValue = quickLinks[i].url }
            box.addSubview(name); box.addSubview(url)
            if let prev = fields.last { prev.1.nextKeyView = name }
            name.nextKeyView = url
            fields.append((name, url))
        }
        alert.accessoryView = box
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = fields[0].0
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        quickLinks = fields.compactMap { name, url in
            let u = url.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let link = QuickLink(title: name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), url: u)
            guard link.destination != nil else { return nil }
            return link.title.isEmpty ? QuickLink(title: link.host, url: u) : link
        }
    }
}

extension NotchState {
    /// Moves one slide along (+1 is to the right, "two fingers to the left"). Stops at the ends.
    func step(_ delta: Int, in slides: [Slide]) {
        guard let i = slides.firstIndex(of: slide) ?? slides.firstIndex(of: .home) else { return }
        let j = min(max(i + delta, 0), slides.count - 1)
        if slides[j] != slide { slide = slides[j] }
    }
}

/// The slides side by side; the strip slides along when `state.slide` changes.
struct SlideDeck: View {
    @Environment(NotchState.self) private var state
    @Environment(AppSettings.self) private var settings

    var body: some View {
        let slides = settings.slides
        let index = slides.firstIndex(of: state.slide) ?? 0
        GeometryReader { geo in
            HStack(spacing: 0) {
                ForEach(slides) { s in
                    Group {
                        switch s {
                        case .home: TilesRow()
                        case .board: BoardSlide()
                        }
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                    // Off-screen slides don't take clicks or VoiceOver focus.
                    .allowsHitTesting(s == slides[index])
                    .opacity(s == slides[index] ? 1 : 0.0)
                    .animation(.easeOut(duration: 0.18), value: index)
                }
            }
            .offset(x: -CGFloat(index) * geo.size.width)
            .animation(.notch, value: index)
        }
        .clipped()
    }
}

/// Dots in the header: which slide is showing. Click one to jump to it.
struct SlideDots: View {
    @Environment(NotchState.self) private var state
    @Environment(AppSettings.self) private var settings

    var body: some View {
        let slides = settings.slides
        if slides.count > 1 {
            HStack(spacing: 5) {
                ForEach(slides) { s in
                    Capsule()
                        .fill(.white.opacity(s == state.slide ? 0.85 : 0.25))
                        .frame(width: s == state.slide ? 12 : 5, height: 5)
                        .contentShape(Rectangle().inset(by: -5))
                        .onTapGesture { state.slide = s }
                        .help("\(s.name): swipe left or right with two fingers to switch slides")
                }
            }
            .animation(.notch, value: state.slide)
        }
    }
}

// MARK: - The second slide

/// The widgets that are switched on, side by side. The calendar takes the room the others leave.
struct BoardSlide: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        let widgets = settings.widgets
        HStack(spacing: NotchLayout.gap) {
            ForEach(widgets) { w in
                switch w {
                case .calendar: TodayTile(compact: widgets.count > 1)
                case .links: LinksTile(wide: widgets.count == 1).frame(width: widgets.count == 1 ? nil : 214)
                }
            }
        }
    }
}

/// Up to four shortcuts; a click opens the link in the default browser and closes the notch.
struct LinksTile: View {
    var wide = false
    @Environment(AppSettings.self) private var settings
    @Environment(NotchState.self) private var state

    var body: some View {
        let links = Array(settings.quickLinks.prefix(QuickLink.limit))
        Tile(padding: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("QUICK LINKS").label()
                    Spacer(minLength: 0)
                    IconButton(symbol: "pencil", size: 18, help: "Edit quick links") { settings.editQuickLinks() }
                }
                .frame(height: 16)
                if links.isEmpty {
                    Spacer(minLength: 0)
                    Button("Add links") { settings.editQuickLinks() }.buttonStyle(PillButtonStyle(theme: settings.theme, prominent: true))
                        .frame(maxWidth: .infinity)
                    Spacer(minLength: 0)
                } else if wide {
                    // Alone on the slide: two columns, so the rows don't stretch across the whole notch.
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible())], spacing: 4) {
                        ForEach(links) { LinkRow(link: $0, theme: settings.theme) { state.collapseAction() } }
                    }
                    Spacer(minLength: 0)
                } else {
                    ForEach(links) { LinkRow(link: $0, theme: settings.theme) { state.collapseAction() } }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

private struct LinkRow: View {
    var link: QuickLink
    var theme: Theme
    var opened: () -> Void
    private let _hover = State(initialValue: false)

    var body: some View {
        let hover = _hover.wrappedValue
        Button {
            if let u = link.destination { NSWorkspace.shared.open(u); opened() }
        } label: {
            HStack(spacing: 8) {
                Text(String(link.title.prefix(1)).uppercased())
                    .font(.system(size: 11, weight: .bold, design: .rounded)).foregroundStyle(.black)
                    .frame(width: 20, height: 20)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(theme.gradient))
                VStack(alignment: .leading, spacing: 0) {
                    Text(link.title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.white.opacity(0.92)).lineLimit(1)
                    Text(link.host).font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.42)).lineLimit(1)
                }
                Spacer(minLength: 2)
                Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(hover ? 0.8 : 0.3))
            }
            .padding(.horizontal, 6)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(hover ? 0.1 : 0.04)))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .onHover { h in _hover.wrappedValue = h }
        .help(link.destination?.absoluteString ?? link.url)
    }
}

// MARK: - Today

/// Today's events from every calendar that's switched on. `compact` when it shares the slide.
struct TodayTile: View {
    var compact = false
    @Environment(CalendarModel.self) private var calendar
    @Environment(AppSettings.self) private var settings
    @Environment(\.snapshotMode) private var snapshot

    var body: some View {
        Tile(padding: 0) {
            if !calendar.hasAccess {
                access
            } else {
                TimelineView(.periodic(from: .now, by: 30)) { ctx in agenda(now: ctx.date) }
            }
        }
    }

    private var access: some View {
        HStack(spacing: 14) {
            DateBadge(date: Date())
            VStack(alignment: .leading, spacing: 6) {
                Text("TODAY").label()
                if calendar.access == .notDetermined {
                    Text("Show today's events from your calendars").font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.7))
                    Button("Show my calendar") { calendar.requestAccess() }.buttonStyle(PillButtonStyle(theme: settings.theme, prominent: true))
                } else {
                    Text("Calendar access is off for Perch").font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.7))
                    Button("Allow in Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                    }.buttonStyle(PillButtonStyle(theme: settings.theme, prominent: true))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
    }

    @ViewBuilder private func agenda(now: Date) -> some View {
        let all = calendar.today.filter { $0.allDay }
        let timed = calendar.today.filter { !$0.allDay }
        let left = timed.filter { $0.end > now }.count
        HStack(alignment: .top, spacing: 0) {
            // Left: the date and a one-line summary.
            VStack(alignment: .leading, spacing: 8) {
                DateBadge(date: now)
                Spacer(minLength: 0)
                Text(summary(left: left, total: timed.count)).font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55)).fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: compact ? 92 : 124, alignment: .leading)
            .padding(14)

            Rectangle().fill(.white.opacity(0.07)).frame(width: 1).padding(.vertical, 12)

            // Right: all-day chips, then the day in time order.
            VStack(alignment: .leading, spacing: 6) {
                if !all.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(all.prefix(3)) { e in
                            HStack(spacing: 5) {
                                Circle().fill(Color(nsColor: e.color)).frame(width: 6, height: 6)
                                Text(e.title).lineLimit(1).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.white.opacity(0.85))
                            }
                            .padding(.horizontal, 8).frame(height: 20)
                            .background(Capsule().fill(.white.opacity(0.07)))
                            .help("All day · \(e.calendar)")
                        }
                        if all.count > 3 { Text("+\(all.count - 3)").font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.45)) }
                        Spacer(minLength: 0)
                    }
                }
                if timed.isEmpty {
                    Spacer(minLength: 0)
                    Text(all.isEmpty ? "Nothing on today" : "No timed events today")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.5))
                        .frame(maxWidth: .infinity)
                    Spacer(minLength: 0)
                } else {
                    // Opens at what's on now (or next), with earlier events a scroll up.
                    let current = timed.first { $0.end > now }?.id
                    let rows = VStack(alignment: .leading, spacing: 2) {
                        ForEach(snapshot ? timed.filter { $0.end > now.addingTimeInterval(-3 * 3600) } : timed) { e in
                            EventRow(event: e, now: now, theme: settings.theme).id(e.id)
                        }
                    }
                    if snapshot {
                        rows.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).clipped()
                    } else {
                        ScrollViewReader { proxy in
                            ScrollView { rows }
                                .scrollIndicators(.never)
                                .onAppear { if let current { proxy.scrollTo(current, anchor: .top) } }
                                .onChange(of: current) { _, c in if let c { withAnimation(.notch) { proxy.scrollTo(c, anchor: .top) } } }
                        }
                    }
                }
            }
            .padding(.vertical, 10).padding(.horizontal, 12)
        }
    }

    private func summary(left: Int, total: Int) -> String {
        if total == 0 { return "Free day" }
        if left == 0 { return "All \(total) done" }
        return left == total ? "\(total) event\(total == 1 ? "" : "s")" : "\(left) of \(total) left"
    }
}

/// "THU" over a big day number.
private struct DateBadge: View {
    var date: Date

    var body: some View {
        VStack(alignment: .leading, spacing: -2) {
            Text(date.formatted(.dateTime.weekday(.wide)).uppercased()).label()
            Text(date.formatted(.dateTime.day()))
                .font(.system(size: 34, weight: .semibold, design: .rounded).monospacedDigit()).foregroundStyle(.white)
            Text(date.formatted(.dateTime.month(.wide))).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.55))
        }
    }
}

private struct EventRow: View {
    var event: CalendarModel.DayEvent
    var now: Date
    var theme: Theme

    var body: some View {
        let over = event.end <= now
        let live = event.start <= now && event.end > now
        HStack(spacing: 8) {
            Text(event.start.formatted(.dateTime.hour().minute()))
                .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(live ? 0.9 : 0.5)).frame(width: 52, alignment: .leading)
            Capsule().fill(Color(nsColor: event.color)).frame(width: 3, height: 16)
            Text(event.title).font(.system(size: 11.5, weight: live ? .semibold : .medium)).lineLimit(1)
                .foregroundStyle(.white.opacity(over ? 0.4 : 0.92))
            Spacer(minLength: 4)
            if live {
                Text("Now").font(.system(size: 9.5, weight: .bold)).foregroundStyle(.black)
                    .padding(.horizontal, 6).frame(height: 15).background(Capsule().fill(theme.gradient))
            } else if !over {
                Text(Self.duration(event)).font(.system(size: 10)).foregroundStyle(.white.opacity(0.38))
            }
            if let url = event.joinURL, !over {
                Button("Join") { NSWorkspace.shared.open(url) }.buttonStyle(PillButtonStyle(theme: theme, prominent: live))
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(live ? 0.08 : 0)))
        .help("\(event.title) · \(event.calendar)")
    }

    static func duration(_ e: CalendarModel.DayEvent) -> String {
        let m = Int(e.end.timeIntervalSince(e.start) / 60)
        if m >= 60 { return m % 60 == 0 ? "\(m / 60)h" : "\(m / 60)h \(m % 60)m" }
        return "\(m)m"
    }
}
