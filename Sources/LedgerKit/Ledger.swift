// Reads the shared ledger that the token-meter Claude Code plugin writes to
// ~/.claude/token-meter/ and turns it into stats. No UI code, no AppKit:
// a menu-bar app or a command-line tool can reuse this target as it is.
import Foundation

/// One model request: `[ts, input, output, cacheRead, cacheWrite, usd, counted?]`.
public struct LedgerRequest: Sendable, Equatable {
    public var ts: Date
    public var input: Double
    public var output: Double
    public var cacheRead: Double
    public var cacheWrite: Double
    public var usd: Double
    /// Tokens as budgets count them (cache reads weighted by price).
    /// Records from token-meter 0.2.0 have none; those weigh cache reads at 0.1.
    public var counted: Double

    public init(ts: Date, input: Double, output: Double, cacheRead: Double, cacheWrite: Double, usd: Double, counted: Double? = nil) {
        self.ts = ts
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.usd = usd
        self.counted = counted ?? (input + output + cacheWrite + cacheRead * 0.1)
    }

    /// A row from the file. Rows with a missing or nonsensical timestamp are dropped;
    /// negative or non-finite amounts count as zero.
    init?(array a: [Double]) {
        guard a.count >= 6, a[0].isFinite, a[0] > 0, a[0] < 32_503_680_000_000 else { return nil } // before year 3000
        // A trillion tokens (or dollars) in one request is corrupt data; cap it so totals stay finite.
        func amt(_ v: Double) -> Double { v.isFinite && v > 0 ? min(v, 1e12) : 0 }
        self.init(ts: Date(timeIntervalSince1970: a[0] / 1000), input: amt(a[1]), output: amt(a[2]), cacheRead: amt(a[3]),
                  cacheWrite: amt(a[4]), usd: amt(a[5]), counted: a.count > 6 ? amt(a[6]) : nil)
    }
}

/// One session's file: `sessions/<id>.json`.
public struct LedgerSession: Sendable, Equatable, Identifiable {
    public var id: String
    public var cwd: String
    public var updatedAt: Date
    /// Estimated tokens streaming right now (only meaningful while `updatedAt` is fresh).
    public var streaming: Double
    public var reqs: [LedgerRequest]

    public init(id: String, cwd: String, updatedAt: Date, streaming: Double, reqs: [LedgerRequest]) {
        self.id = id
        self.cwd = cwd
        self.updatedAt = updatedAt
        self.streaming = streaming
        self.reqs = reqs
    }

    /// The folder's name, or "Claude" when the session has no folder.
    public var project: String {
        let name = (cwd as NSString).lastPathComponent
        if cwd.contains("/scratch-workspaces/") { return "No folder" }
        return name.isEmpty || name == "/" ? "Claude" : name
    }
}

/// `budget.json`: a budget shared by every session over a rolling window.
public struct LedgerBudget: Sendable, Equatable, Codable {
    public var tokens: Double?
    public var usd: Double?
    public var windowHours: Double

    public init(tokens: Double? = nil, usd: Double? = nil, windowHours: Double = 5) {
        self.tokens = Self.positive(tokens)
        self.usd = Self.positive(usd)
        self.windowHours = Self.hours(windowHours)
    }

    /// Tolerates a missing window, zero, negative or absurd values: a hand-edited file can't break the app.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func num(_ k: CodingKeys) -> Double? { (try? c.decodeIfPresent(Double.self, forKey: k)) ?? nil }
        self.init(tokens: num(.tokens), usd: num(.usd), windowHours: num(.windowHours) ?? 5)
    }

    private static func positive(_ v: Double?) -> Double? {
        guard let v, v.isFinite, v > 0 else { return nil }
        return v
    }

    /// Between one minute and 31 days; anything else falls back to token-meter's default of 5 hours.
    private static func hours(_ h: Double) -> Double {
        h.isFinite && h >= 1.0 / 60 && h <= 24 * 31 ? h : 5
    }

    /// "5h", "1.5h", "30m".
    public var windowText: String {
        if windowHours < 1 { return "\(Int((windowHours * 60).rounded()))m" }
        let r = (windowHours * 10).rounded() / 10
        return r == r.rounded() ? "\(Int(r))h" : String(format: "%.1fh", r)
    }
}

public enum Ledger {
    /// A session that hasn't written for this long isn't streaming any more.
    public static let staleAfter: TimeInterval = 60
    /// The burn-rate window token-meter uses.
    public static let burnWindow: TimeInterval = 5 * 60
    /// token-meter suggests a lighter model above this many counted tokens a minute.
    public static let burnWarnPerMinute: Double = 40_000

    /// `$CLAUDE_CONFIG_DIR/token-meter`, else `~/.claude/token-meter`.
    public static var defaultDirectory: URL {
        if let cfg = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !cfg.isEmpty {
            return URL(fileURLWithPath: cfg).appendingPathComponent("token-meter")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/token-meter")
    }

    public static func parseSession(_ data: Data) -> LedgerSession? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["id"] as? String else { return nil }
        // Row by row, so one malformed row doesn't throw the rest away.
        let reqs = (obj["reqs"] as? [Any] ?? []).compactMap { row -> LedgerRequest? in
            guard let row = row as? [Any] else { return nil }
            return LedgerRequest(array: row.map { ($0 as? NSNumber)?.doubleValue ?? 0 })
        }
        var updated = (obj["updatedAt"] as? NSNumber)?.doubleValue ?? 0
        if !updated.isFinite || updated < 0 || updated > 32_503_680_000_000 { updated = 0 }
        let streaming = (obj["streaming"] as? NSNumber)?.doubleValue ?? 0
        return LedgerSession(id: id, cwd: obj["cwd"] as? String ?? "",
                             updatedAt: Date(timeIntervalSince1970: updated / 1000),
                             streaming: streaming.isFinite && streaming > 0 ? streaming : 0, reqs: reqs)
    }

    /// Every session file touched since `since`. Files older than that can't hold anything newer.
    public static func readSessions(in dir: URL = defaultDirectory, since: Date) -> [LedgerSession] {
        let sessions = dir.appendingPathComponent("sessions")
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(at: sessions, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { return [] }
        return names.compactMap { url in
            guard url.pathExtension == "json" else { return nil }
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            // Skip anything that isn't a plain file or is implausibly large for a session (a corrupt or foreign file).
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            guard mtime >= since, size <= 64 << 20, let data = try? Data(contentsOf: url) else { return nil }
            return parseSession(data)
        }
    }

    public static func readBudget(in dir: URL = defaultDirectory) -> LedgerBudget? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("budget.json")) else { return nil }
        return try? JSONDecoder().decode(LedgerBudget.self, from: data)
    }
}

/// What one session is doing right now.
public struct SessionActivity: Sendable, Equatable, Identifiable {
    public enum State: Sendable, Equatable { case responding, active, idle }
    public var id: String
    public var project: String
    public var state: State
    /// Counted tokens inside the stats window.
    public var windowTokens: Double
    public var streaming: Double
    public var lastActivity: Date
}

/// Everything the notch shows about Claude Code, computed from one read of the ledger.
public struct ClaudeStats: Sendable, Equatable {
    public var windowHours: Double = 5
    /// Counted tokens in the last `windowHours`, including what's streaming now.
    public var windowTokens: Double = 0
    public var windowUSD: Double = 0
    public var todayTokens: Double = 0
    public var todayUSD: Double = 0
    /// Counted tokens a minute over the last five minutes.
    public var burnPerMinute: Double = 0
    /// Counted tokens per minute for each of the last 30 minutes, oldest first.
    public var burnHistory: [Double] = Array(repeating: 0, count: 30)
    public var sessions: [SessionActivity] = []
    public var budget: LedgerBudget?
    /// The model the busiest current session uses (see `Transcript`), when it can be found.
    public var model: String?

    public init() {}

    public var responding: [SessionActivity] { sessions.filter { $0.state == .responding } }
    public var isResponding: Bool { !responding.isEmpty }
    public var streamingTokens: Double { responding.reduce(0) { $0 + $1.streaming } }

    /// Fraction of the token budget used (0…), or nil with no token budget.
    public var budgetUsedFraction: Double? {
        if let t = budget?.tokens, t > 0 { return windowTokens / t }
        if let u = budget?.usd, u > 0 { return windowUSD / u }
        return nil
    }

    /// What's left of the budget, as text ("1.2M left", "$3.40 left", "over by 200k").
    public var budgetRemainingText: String? {
        if let t = budget?.tokens, t > 0 {
            let left = t - windowTokens
            return left >= 0 ? "\(TokenFormat.short(left)) left" : "over by \(TokenFormat.short(-left))"
        }
        if let u = budget?.usd, u > 0 {
            let left = u - windowUSD
            return left >= 0 ? String(format: "$%.2f left", left) : String(format: "over by $%.2f", -left)
        }
        return nil
    }

    /// Minutes until the budget runs out at the current burn rate (nil when that's more than a day away).
    public var minutesToBudget: Double? {
        guard let t = budget?.tokens, t > 0, burnPerMinute > 0 else { return nil }
        let m = max(0, (t - windowTokens) / burnPerMinute)
        return m.isFinite && m <= 24 * 60 ? m : nil
    }

    /// Percent of the budget left, clamped to 0…100 (nil with no budget).
    public var budgetPercentLeft: Int? {
        guard let f = budgetUsedFraction, f.isFinite else { return nil }
        return Int((max(0, min(1, 1 - f)) * 100).rounded())
    }

    /// "5h", "1.5h", "30m": the stats window.
    public var windowText: String { LedgerBudget(windowHours: windowHours).windowText }

    public static func compute(sessions files: [LedgerSession], budget: LedgerBudget?, now: Date = Date(),
                               calendar: Calendar = .current) -> ClaudeStats {
        var s = ClaudeStats()
        s.budget = budget
        s.windowHours = LedgerBudget(windowHours: budget?.windowHours ?? 5).windowHours
        let windowFrom = now.addingTimeInterval(-s.windowHours * 3600)
        let dayFrom = calendar.startOfDay(for: now)
        let burnFrom = now.addingTimeInterval(-Ledger.burnWindow)
        let historyFrom = now.addingTimeInterval(-30 * 60)

        for f in files {
            var inWindow = 0.0
            var last = f.updatedAt
            for r in f.reqs {
                if r.ts >= windowFrom {
                    inWindow += r.counted
                    s.windowTokens += r.counted
                    s.windowUSD += r.usd
                }
                if r.ts >= dayFrom {
                    s.todayTokens += r.counted
                    s.todayUSD += r.usd
                }
                if r.ts >= burnFrom { s.burnPerMinute += r.counted }
                // Requests stamped in the future (clock changes) count as "now".
                if r.ts >= historyFrom {
                    let minute = min(29, max(0, r.ts.timeIntervalSince(historyFrom) / 60))
                    s.burnHistory[Int(minute)] += r.counted
                }
                last = max(last, min(r.ts, now))
            }
            let fresh = now.timeIntervalSince(f.updatedAt) < Ledger.staleAfter
            let streaming = fresh ? f.streaming : 0
            s.windowTokens += streaming
            s.todayTokens += streaming
            let state: SessionActivity.State =
                streaming > 0 ? .responding : (now.timeIntervalSince(last) < 10 * 60 ? .active : .idle)
            if inWindow > 0 || state != .idle {
                s.sessions.append(SessionActivity(id: f.id, project: f.project, state: state, windowTokens: inWindow + streaming,
                                                  streaming: streaming, lastActivity: last))
            }
        }
        s.burnPerMinute /= Ledger.burnWindow / 60
        s.sessions.sort { a, b in
            func rank(_ x: SessionActivity.State) -> Int { x == .responding ? 0 : x == .active ? 1 : 2 }
            return rank(a.state) != rank(b.state) ? rank(a.state) < rank(b.state) : a.lastActivity > b.lastActivity
        }
        return s
    }
}

public enum TokenFormat {
    /// 950 → "950", 12_400 → "12.4k", 3_400_000 → "3.4M".
    public static func short(_ n: Double) -> String {
        guard n.isFinite else { return "—" }
        func trim(_ v: Double) -> String {
            let s = abs(v) >= 100 ? String(format: "%.0f", v) : String(format: "%.1f", v)
            return s.hasSuffix(".0") ? String(s.dropLast(2)) : s
        }
        // Round first, then pick the unit, so 999,950 reads "1M" rather than "1000k".
        var v = n
        for unit in ["", "k", "M", "B", "T"] {
            let shown = unit.isEmpty ? v.rounded() : (abs(v) >= 100 ? v.rounded() : (v * 10).rounded() / 10)
            if abs(shown) < 1000 || unit == "T" { return unit.isEmpty ? String(format: "%.0f", shown) : trim(shown) + unit }
            v /= 1000
        }
        return trim(v)
    }
}
