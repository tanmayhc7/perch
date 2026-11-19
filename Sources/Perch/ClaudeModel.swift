import AppKit
import Foundation
import LedgerKit

/// Polls token-meter's ledger and raises budget, burn-rate and "finished" alerts.
@MainActor @Observable
final class ClaudeModel {
    var stats = ClaudeStats()
    /// token-meter has written a ledger on this Mac.
    var ledgerFound = true
    /// The ledger has been read at least once.
    var loaded = false

    @ObservationIgnored var onAlert: ((Toast) -> Void)?
    @ObservationIgnored var finishAlertsEnabled: () -> Bool = { true }
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let dir = Ledger.defaultDirectory
    @ObservationIgnored private let queue = DispatchQueue(label: "perch.ledger", qos: .utility)
    @ObservationIgnored private let modelCache = TranscriptModels()

    // Alert bookkeeping.
    @ObservationIgnored private var firedBudget: Set<Int> = []
    @ObservationIgnored private var lastBurnAlert = Date.distantPast
    /// When each session started responding (for the "finished" alert).
    @ObservationIgnored private var respondingSince: [String: Date] = [:]
    @ObservationIgnored private var quietSince: [String: Date] = [:]
    @ObservationIgnored private var first = true

    func start() {
        refresh()
        // Fast while something is streaming, slower when nothing is.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.tick += 1
                if self.stats.isResponding || self.tick % 3 == 0 { self.refresh() }
            }
        }
    }
    @ObservationIgnored private var tick = 0

    /// A read is under way; skip ticks until it finishes so slow disks can't pile reads up.
    @ObservationIgnored private var reading = false

    /// Asks first, since the budget is shared by every Claude Code session, then clears it (see `Ledger.clearBudget`).
    func confirmClearBudget() {
        guard stats.budget?.tokens != nil || stats.budget?.usd != nil else { return }
        let alert = NSAlert()
        alert.messageText = "Clear your Claude Code token budget?"
        let what = [stats.budget?.tokens.map { "\(TokenFormat.short($0)) tokens" }, stats.budget?.usd.map { String(format: "$%.2f", $0) }]
            .compactMap { $0 }.joined(separator: " and ")
        alert.informativeText = "This removes the all-sessions budget (\(what) over \(stats.budget?.windowText ?? "5h")) for every Claude Code session, "
            + "the same as /token-budget all off. Set a new one any time with /token-budget all 5M; Undo in the next notice puts it back."
        alert.addButton(withTitle: "Clear budget")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        clearBudget()
    }

    enum BudgetField { case tokens, dollars, window }

    /// Changes the shared budget (see `Ledger.updateBudget`); Claude Code sessions read it on their next update.
    func setBudget(tokens: BudgetLimit = .keep, usd: BudgetLimit = .keep, windowHours: Double? = nil) {
        let dir = self.dir
        queue.async {
            let ok = Ledger.updateBudget(tokens: tokens, usd: usd, windowHours: windowHours, in: dir)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if ok {
                        // A new limit can be warned about afresh.
                        self.firedBudget = []
                        self.refresh()
                    } else {
                        self.onAlert?(Toast(symbol: "exclamationmark.triangle.fill", tint: .warning, title: "Couldn't change the budget",
                                            subtitle: "token-meter's budget file wasn't changed"))
                    }
                }
            }
        }
    }

    /// A value of your own for one budget option, typed the way token-meter takes it (`3M`, `$15`, `12h`).
    func promptBudget(_ field: BudgetField) {
        let alert = NSAlert()
        let hint: String
        switch field {
        case .tokens: alert.messageText = "Token budget"; hint = "e.g. 3M or 750k"
        case .dollars: alert.messageText = "Dollar budget"; hint = "e.g. 15 or $15"
        case .window: alert.messageText = "Budget window"; hint = "e.g. 12h, 3d (from 1 minute to 31 days)"
        }
        alert.informativeText = "For every Claude Code session together. Same as /token-budget all in Claude Code."
        let box = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        box.placeholderString = hint
        alert.accessoryView = box
        alert.addButton(withTitle: "Set")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = box
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let text = box.stringValue
        switch field {
        case .tokens:
            if let v = Ledger.parseAmount(text) { setBudget(tokens: .set(v)) } else { invalid(text, hint) }
        case .dollars:
            if let v = Ledger.parseAmount(text) { setBudget(usd: .set(v)) } else { invalid(text, hint) }
        case .window:
            if let v = Ledger.parseWindowHours(text) { setBudget(windowHours: v) } else { invalid(text, hint) }
        }
    }

    private func invalid(_ text: String, _ hint: String) {
        onAlert?(Toast(symbol: "questionmark.circle.fill", tint: .warning, title: "Couldn't read “\(text.prefix(20))”", subtitle: "Try \(hint)"))
    }

    func clearBudget() {
        let dir = self.dir
        queue.async {
            let previous = Ledger.clearBudget(in: dir)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let previous else {
                        self.onAlert?(Toast(symbol: "exclamationmark.triangle.fill", tint: .warning, title: "Couldn't clear the budget",
                                            subtitle: "token-meter's budget file wasn't changed"))
                        return
                    }
                    self.firedBudget = []
                    self.refresh()
                    self.onAlert?(Toast(symbol: "checkmark.circle.fill", tint: .calm, title: "Token budget cleared",
                                        subtitle: "For every Claude Code session",
                                        actionTitle: "Undo", action: { [weak self] in self?.restoreBudget(previous) }, seconds: 10))
                }
            }
        }
    }

    private func restoreBudget(_ previous: LedgerBudget) {
        let dir = self.dir
        queue.async {
            let ok = Ledger.restoreBudget(previous, in: dir)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.refresh()
                    self.onAlert?(Toast(symbol: ok ? "arrow.uturn.backward.circle.fill" : "exclamationmark.triangle.fill", tint: ok ? .calm : .warning,
                                        title: ok ? "Token budget restored" : "Couldn't restore the budget",
                                        subtitle: ok ? nil : "A new budget has been set since"))
                }
            }
        }
    }

    func refresh() {
        guard !reading else { return }
        reading = true
        let dir = self.dir
        queue.async {
            let now = Date()
            let budget = Ledger.readBudget(in: dir)
            let hours = max(budget?.windowHours ?? 5, 5)
            let since = min(Calendar.current.startOfDay(for: now), now.addingTimeInterval(-hours * 3600))
            let found = FileManager.default.fileExists(atPath: dir.appendingPathComponent("sessions").path)
            let files = Ledger.readSessions(in: dir, since: since)
            var s = ClaudeStats.compute(sessions: files, budget: budget, now: now)
            s.model = self.currentModel(of: s)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.reading = false
                    self.ledgerFound = found
                    if !self.loaded { self.loaded = true }
                    if s != self.stats { self.stats = s }
                    self.checkAlerts(s, now: now)
                    self.first = false
                }
            }
        }
    }

    /// The model of the session that's responding, else the most recently active one.
    /// Runs on the ledger queue. The transcript is read again only when it has changed.
    nonisolated private func currentModel(of s: ClaudeStats) -> String? {
        guard let session = s.responding.first ?? s.sessions.max(by: { $0.lastActivity < $1.lastActivity }) else { return nil }
        let id = session.id
        guard let url = modelCache.path(for: id) else { return nil }
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return modelCache.model(for: id, url: url, mtime: mtime)
    }

    private func checkAlerts(_ s: ClaudeStats, now: Date) {
        // Budget: once at 80% and once at 100%, re-armed when usage falls back under.
        if let f = s.budgetUsedFraction {
            for (pct, tint) in [(100, Toast.ToastTint.danger), (80, .warning)] where f * 100 >= Double(pct) {
                if !firedBudget.contains(pct) {
                    firedBudget.insert(pct)
                    if pct == 100 { firedBudget.insert(80) }
                    if !first {
                        onAlert?(Toast(symbol: pct == 100 ? "exclamationmark.octagon.fill" : "gauge.with.dots.needle.67percent",
                                       tint: tint,
                                       title: pct == 100 ? "Claude budget used up" : "80% of your Claude budget used",
                                       subtitle: "\(TokenFormat.short(s.windowTokens)) in \(s.windowText) · \(s.budgetRemainingText ?? "")",
                                       seconds: 8))
                    }
                }
                break
            }
            if f < 0.8 { firedBudget.removeAll() } else if f < 1 { firedBudget.remove(100) }
        }

        // Burn rate: at most every 15 minutes.
        if s.burnPerMinute >= Ledger.burnWarnPerMinute, now.timeIntervalSince(lastBurnAlert) > 15 * 60 {
            lastBurnAlert = now
            var sub = "A lighter model (/model sonnet) costs much less"
            if let m = s.minutesToBudget { sub = "Budget gone in ~\(max(1, Int(m.rounded()))) min at this rate" }
            onAlert?(Toast(symbol: "flame.fill", tint: .warning,
                           title: "Burning \(TokenFormat.short(s.burnPerMinute)) tokens/min", subtitle: sub, seconds: 8))
        }

        // Finished: a session that streamed for a while has been quiet for a few seconds.
        let responding = Set(s.responding.map(\.id))
        for id in responding {
            if respondingSince[id] == nil { respondingSince[id] = now }
            quietSince[id] = nil
        }
        for (id, since) in respondingSince where !responding.contains(id) {
            let quiet = quietSince[id] ?? now
            quietSince[id] = quiet
            if now.timeIntervalSince(quiet) >= 10 {
                if quiet.timeIntervalSince(since) >= 8, finishAlertsEnabled() {
                    let project = s.sessions.first { $0.id == id }?.project ?? "Claude Code"
                    onAlert?(Toast(symbol: "checkmark.seal.fill", tint: .calm, title: "Claude finished",
                                   subtitle: project, seconds: 4))
                }
                respondingSince[id] = nil
                quietSince[id] = nil
            }
        }
    }
}


/// Finds each session's transcript once and rereads its model only when the file changes.
/// Used from the ledger queue only.
private final class TranscriptModels: @unchecked Sendable {
    private var paths: [String: URL] = [:]
    private var models: [String: (mtime: Date?, model: String?)] = [:]
    private let lock = NSLock()

    func path(for id: String) -> URL? {
        lock.lock(); defer { lock.unlock() }
        if let p = paths[id], FileManager.default.fileExists(atPath: p.path) { return p }
        paths[id] = Transcript.find(sessionID: id)
        return paths[id]
    }

    func model(for id: String, url: URL, mtime: Date?) -> String? {
        lock.lock(); defer { lock.unlock() }
        if let c = models[id], c.mtime == mtime { return c.model }
        let m = Transcript.latestModel(at: url)
        models[id] = (mtime, m ?? models[id]?.model)
        return models[id]?.model
    }
}
