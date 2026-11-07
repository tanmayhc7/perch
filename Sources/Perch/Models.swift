import AppKit
import EventKit
import UniformTypeIdentifiers

// MARK: - Shelf and AirDrop

/// Files dropped on the notch, held until they're dragged out again or cleared.
/// The shelf keeps references to the original files; it never copies or moves them.
@MainActor @Observable
final class ShelfModel {
    struct Item: Identifiable, Equatable {
        let id = UUID()
        let url: URL
        /// The Finder icon, flattened to a bitmap once.
        let icon: NSImage
        var name: String { url.lastPathComponent }

        init(url: URL) {
            self.url = url
            let src = NSWorkspace.shared.icon(forFile: url.path)
            let px = 64
            if let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                                          hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                src.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
                NSGraphicsContext.restoreGraphicsState()
                let img = NSImage(size: NSSize(width: 32, height: 32))
                img.addRepresentation(rep)
                icon = img
            } else {
                icon = src
            }
        }
    }

    var items: [Item] = []

    func add(_ urls: [URL]) {
        for u in urls where !items.contains(where: { $0.url == u }) { items.append(Item(url: u)) }
    }

    func remove(_ item: Item) { items.removeAll { $0.id == item.id } }
    func clear() { items.removeAll() }

    static func airDrop(_ urls: [URL]) {
        guard !urls.isEmpty, let service = NSSharingService(named: .sendViaAirDrop) else { return }
        NSApp.activate(ignoringOtherApps: true)
        service.perform(withItems: urls)
    }

    /// File URLs from a SwiftUI drop.
    static func loadURLs(_ providers: [NSItemProvider], done: @escaping @MainActor ([URL]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.isFileURL { lock.lock(); urls.append(url); lock.unlock() }
                group.leave()
            }
        }
        group.notify(queue: .main) { MainActor.assumeIsolated { done(urls) } }
    }
}

// MARK: - Calendar

/// The next meeting today, and a Join button when it has a video link.
@MainActor @Observable
final class CalendarModel {
    struct Meeting: Equatable {
        var title: String
        var start: Date
        var end: Date
        var joinURL: URL?
        var color: NSColor
    }

    var access: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)
    var next: Meeting?

    @ObservationIgnored var onAlert: ((Toast) -> Void)?
    @ObservationIgnored private let store = EKEventStore()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var alerted: Set<String> = []

    var hasAccess: Bool { access == .fullAccess }

    func start() {
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        reload()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    /// Asks for Calendar access only when the person clicks the tile's button.
    func requestAccess() {
        NSApp.activate(ignoringOtherApps: true)
        store.requestFullAccessToEvents { _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self.access = EKEventStore.authorizationStatus(for: .event); self.reload() } }
        }
    }

    func reload() {
        access = EKEventStore.authorizationStatus(for: .event)
        guard hasAccess else { next = nil; return }
        let now = Date()
        let pred = store.predicateForEvents(withStart: now.addingTimeInterval(-15 * 60), end: now.addingTimeInterval(24 * 3600), calendars: nil)
        let events = store.events(matching: pred)
            .filter { !$0.isAllDay && $0.endDate > now && $0.status != .canceled }
            .filter { e in
                // Skip events the person declined.
                e.attendees?.first(where: { $0.isCurrentUser })?.participantStatus != .declined
            }
            .sorted { $0.startDate < $1.startDate }
        guard let e = events.first else { next = nil; return }
        let m = Meeting(title: e.title ?? "Event", start: e.startDate, end: e.endDate,
                        joinURL: Self.joinURL(e), color: e.calendar?.color ?? .systemBlue)
        next = m
        // Slide out two minutes before it starts.
        let key = "\(e.eventIdentifier ?? m.title)-\(m.start.timeIntervalSince1970)"
        let until = m.start.timeIntervalSince(now)
        if until > 0, until <= 120, !alerted.contains(key) {
            alerted.insert(key)
            let url = m.joinURL
            onAlert?(Toast(symbol: "video.fill", tint: .calm, title: m.title, subtitle: "Starts in \(max(1, Int(until / 60))) min",
                           actionTitle: url == nil ? nil : "Join", action: url.map { u in { NSWorkspace.shared.open(u) } }, seconds: 12))
        }
    }

    private static let linkPattern = try! NSRegularExpression(
        pattern: #"https://[^\s<>"']*(zoom\.us|meet\.google\.com|teams\.microsoft\.com|teams\.live\.com|webex\.com|whereby\.com|facetime\.apple\.com|around\.co|chime\.aws|meet\.jit\.si)[^\s<>"']*"#,
        options: [.caseInsensitive])

    static func joinURL(_ e: EKEvent) -> URL? {
        let fields = [e.url?.absoluteString, e.location, e.notes].compactMap { $0 }
        for f in fields {
            let r = NSRange(f.startIndex..., in: f)
            if let m = linkPattern.firstMatch(in: f, range: r), let range = Range(m.range, in: f) {
                return URL(string: String(f[range]))
            }
        }
        return nil
    }
}

// MARK: - Focus timer

@MainActor @Observable
final class FocusTimer {
    enum Phase { case idle, running, paused }

    var phase: Phase = .idle
    var total: TimeInterval = 25 * 60
    var endsAt = Date()
    var remainingWhenPaused: TimeInterval = 0
    var label = "Focus"

    @ObservationIgnored var onAlert: ((Toast) -> Void)?
    @ObservationIgnored private var timer: Timer?

    func remaining(at now: Date) -> TimeInterval {
        switch phase {
        case .idle: total
        case .paused: remainingWhenPaused
        case .running: max(0, endsAt.timeIntervalSince(now))
        }
    }

    func progress(at now: Date) -> Double { total > 0 ? 1 - remaining(at: now) / total : 0 }

    func start(minutes: Double, label: String) {
        total = minutes * 60
        self.label = label
        endsAt = Date().addingTimeInterval(total)
        phase = .running
        schedule()
    }

    func toggle() {
        switch phase {
        case .idle: start(minutes: total / 60, label: label)
        case .running:
            remainingWhenPaused = remaining(at: Date())
            phase = .paused
            timer?.invalidate()
        case .paused:
            endsAt = Date().addingTimeInterval(remainingWhenPaused)
            phase = .running
            schedule()
        }
    }

    func stop() {
        phase = .idle
        timer?.invalidate()
    }

    private func schedule() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: max(0.1, endsAt.timeIntervalSinceNow), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish() }
        }
    }

    private func finish() {
        guard phase == .running else { return }
        phase = .idle
        NSSound(named: "Glass")?.play()
        onAlert?(Toast(symbol: "checkmark.circle.fill", tint: .calm, title: "\(label) done",
                       subtitle: "\(Int(total / 60)) minutes", actionTitle: "Again",
                       action: { [weak self] in guard let self else { return }; self.start(minutes: self.total / 60, label: self.label) },
                       seconds: 10))
    }

    static func format(_ t: TimeInterval) -> String {
        let s = Int(t.rounded(.up))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
