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

    func refresh() {
        let dir = self.dir
        queue.async {
            let now = Date()
            let budget = Ledger.readBudget(in: dir)
            let hours = max(budget?.windowHours ?? 5, 5)
            let since = min(Calendar.current.startOfDay(for: now), now.addingTimeInterval(-hours * 3600))
            let found = FileManager.default.fileExists(atPath: dir.appendingPathComponent("sessions").path)
            let files = Ledger.readSessions(in: dir, since: since)
            let s = ClaudeStats.compute(sessions: files, budget: budget, now: now)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.ledgerFound = found
                    if !self.loaded { self.loaded = true }
                    if s != self.stats { self.stats = s }
                    self.checkAlerts(s, now: now)
                    self.first = false
                }
            }
        }
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
                                       subtitle: "\(TokenFormat.short(s.windowTokens)) in \(Int(s.windowHours))h · \(s.budgetRemainingText ?? "")",
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
            if let m = s.minutesToBudget { sub = "Budget gone in ~\(Int(m.rounded())) min at this rate" }
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
