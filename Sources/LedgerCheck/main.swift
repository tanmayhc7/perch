// Checks for LedgerKit. Run with `swift run LedgerCheck`.
// A plain executable because the Command Line Tools ship neither XCTest nor the swift-testing macros.
import Foundation
import LedgerKit

var failures = 0
func check<T: Equatable>(_ a: T, _ b: T, _ what: String, line: Int = #line) {
    if a != b { failures += 1; print("✗ line \(line): \(what): got \(a), expected \(b)") }
}
func unwrap<T>(_ v: T?, _ what: String) -> T {
    guard let v else { print("✗ \(what) was nil"); exit(1) }
    return v
}

let now = Date(timeIntervalSince1970: 1_800_000_000)

// testFindsTheModelInATranscriptTail
do {
    func line(_ type: String, model: String? = nil, extra: String = "") -> String {
        let m = model.map { ",\"model\":\"\($0)\"" } ?? ""
        return "{\"type\":\"\(type)\",\"message\":{\"role\":\"x\"\(m)}\(extra)}"
    }
    let t = [line("assistant", model: "claude-opus-5-5"), line("user"), line("assistant", model: "claude-sonnet-5-5"),
             line("user", extra: ",\"note\":\"{\\\"model\\\":\\\"claude-haiku-5-5\\\"}\""), line("assistant", model: "<synthetic>")].joined(separator: "\n")
    // Newest real assistant model: skips the synthetic one and the user line that only mentions a model.
    check(Transcript.modelName(inTail: Data(t.utf8)), "claude-sonnet-5-5", "newest model")
    check(Transcript.modelName(inTail: Data(line("user").utf8)), nil, "no assistant line")
    check(Transcript.modelName(inTail: Data("not json\n{broken".utf8)), nil, "garbage")
    // A cut-off first line is skipped, not misread.
    let cut = "ant\",\"model\":\"claude-opus-5-5\"}}\n" + line("user")
    check(Transcript.modelName(inTail: Data(cut.utf8), startsMidLine: true), nil, "cut-off first line")
    check(Transcript.find(sessionID: "../etc/passwd"), nil, "path-like id refused")
}

// testNamesModelsForPeople
do {
    check(Transcript.displayName("claude-sonnet-5-5"), "Sonnet 5.5", "sonnet 5.5")
    check(Transcript.displayName("claude-opus-4-1-20250805"), "Opus 4.1", "dated opus")
    check(Transcript.displayName("claude-3-5-sonnet-20241022"), "Sonnet 3.5", "old order")
    check(Transcript.displayName("claude-fable-5-1"), "Fable 5.1", "fable")
    check(Transcript.displayName("claude-opus-4-1[1m]"), "Opus 4.1 (1M)", "context window")
    check(Transcript.displayName("claude-haiku-5-5"), "Haiku 5.5", "haiku")
    check(Transcript.displayName("gpt-something"), "gpt-something", "unknown stays as is")
}

func ms(_ d: Date) -> Double { d.timeIntervalSince1970 * 1000 }

// testParsesSessionFile
do {
    let json = """
    {"id":"abc","cwd":"/Users/me/Desktop/proj","updatedAt":\(ms(now)),"streaming":120,
     "reqs":[[\(ms(now) - 60_000),2,100,1000,50,0.01,252],[\(ms(now) - 30_000),1,10,500,0,0.001]]}
    """
    let s = unwrap(Ledger.parseSession(Data(json.utf8)), "parsed session")
    check(s.project, "proj", "s.project")
    check(s.reqs.count, 2, "s.reqs.count")
    check(s.reqs[0].counted, 252, "s.reqs[0].counted")
    // No `counted`: cache reads weigh 0.1.
    check(s.reqs[1].counted, 1 + 10 + 0 + 50, "s.reqs[1].counted")
}

// testComputesWindowBurnAndBudget
do {
    let old = LedgerRequest(ts: now.addingTimeInterval(-6 * 3600), input: 0, output: 0, cacheRead: 0, cacheWrite: 0, usd: 1, counted: 1_000_000)
    let recent = LedgerRequest(ts: now.addingTimeInterval(-60), input: 0, output: 0, cacheRead: 0, cacheWrite: 0, usd: 0.5, counted: 50_000)
    let a = LedgerSession(id: "a", cwd: "/x/alpha", updatedAt: now.addingTimeInterval(-5), streaming: 2_000, reqs: [old, recent])
    let b = LedgerSession(id: "b", cwd: "/x/beta", updatedAt: now.addingTimeInterval(-600), streaming: 9_999, reqs: [old])
    let st = ClaudeStats.compute(sessions: [a, b], budget: LedgerBudget(tokens: 100_000), now: now)
    check(st.windowTokens, 52_000, "st.windowTokens")
    check(st.burnPerMinute, 10_000, "st.burnPerMinute")
    check(st.responding.map(\.id), ["a"], "responding ids")
    check(st.sessions.count, 1, "st.sessions.count") // b is idle with nothing in the window; its stale streaming is ignored
    check(st.budgetRemainingText, "48k left", "st.budgetRemainingText")
    check(st.minutesToBudget, 4.8, "st.minutesToBudget")
}

// testDollarBudget
do {
    let r = LedgerRequest(ts: now.addingTimeInterval(-60), input: 0, output: 0, cacheRead: 0, cacheWrite: 0, usd: 4, counted: 1)
    let s = LedgerSession(id: "a", cwd: "/x/a", updatedAt: now, streaming: 0, reqs: [r])
    let st = ClaudeStats.compute(sessions: [s], budget: LedgerBudget(usd: 5), now: now)
    check(st.budgetUsedFraction, 0.8, "st.budgetUsedFraction")
    check(st.budgetRemainingText, "$1.00 left", "st.budgetRemainingText")
}

// testFormatsTokens
do {
    check(TokenFormat.short(950), "950", "TokenFormat.short(950)")
    check(TokenFormat.short(12_400), "12.4k", "TokenFormat.short(12_400)")
    check(TokenFormat.short(3_000_000), "3M", "TokenFormat.short(3_000_000)")
    check(TokenFormat.short(250_000), "250k", "TokenFormat.short(250_000)")
}


// testHostileLedgerData: nothing in a hand-edited or corrupt ledger may crash the app.
do {
    let j = """
    {"id":"x","cwd":"/","updatedAt":1e300,"streaming":-5,
     "reqs":[[1e300,1,1,1,1,1],[\(ms(now) - 60_000),-100,10,0,0,-1],"junk",null,[1,2],[\(ms(now) - 30_000),"a",5,0,0,0.1]]}
    """
    let s = unwrap(Ledger.parseSession(Data(j.utf8)), "hostile session")
    check(s.reqs.count, 2, "bad rows dropped one by one, good rows kept")
    check(s.reqs[0].input, 0, "negative amounts count as zero")
    check(s.streaming, 0, "negative streaming ignored")
    check(s.project, "Claude", "root folder shows as Claude")
    let st = ClaudeStats.compute(sessions: [s], budget: LedgerBudget(tokens: 1e-300), now: now)
    check(st.burnHistory.reduce(0, +), 15, "burn history from the two good rows")
    check(st.budgetPercentLeft, 0, "a tiny budget clamps to 0% left")
    let far = LedgerRequest(ts: now.addingTimeInterval(1e15), input: 1, output: 1, cacheRead: 0, cacheWrite: 0, usd: 0)
    let st2 = ClaudeStats.compute(sessions: [LedgerSession(id: "f", cwd: "/a", updatedAt: now, streaming: 0, reqs: [far])], budget: nil, now: now)
    check(st2.burnHistory[29], 2, "future request lands in the newest minute")
    check(Ledger.parseSession(Data("not json".utf8)) == nil, true, "garbage file")
    check(Ledger.parseSession(Data("[1,2]".utf8)) == nil, true, "array file")
}

// testTolerantBudget
do {
    func decode(_ s: String) -> LedgerBudget? { try? JSONDecoder().decode(LedgerBudget.self, from: Data(s.utf8)) }
    check(decode(#"{"tokens":5000000}"#)?.windowHours, 5, "missing window defaults to 5h")
    check(decode(#"{"tokens":-3,"windowHours":-2}"#), LedgerBudget(), "negative values ignored")
    check(decode(#"{"tokens":"lots","windowHours":1e300}"#), LedgerBudget(), "wrong types and absurd windows ignored")
    check(decode(#"{"usd":5,"windowHours":0.5}"#)?.windowText, "30m", "half-hour window")
    check(LedgerBudget(windowHours: 1.5).windowText, "1.5h", "fractional window")
    let huge = LedgerRequest(ts: now.addingTimeInterval(-60), input: 0, output: 0, cacheRead: 0, cacheWrite: 0, usd: 0, counted: 300_000)
    let st = ClaudeStats.compute(sessions: [LedgerSession(id: "a", cwd: "/a", updatedAt: now, streaming: 0, reqs: [huge])],
                                 budget: LedgerBudget(tokens: 1e30), now: now)
    check(st.minutesToBudget == nil, true, "budget days away: no countdown")
}

// testFormatsEdgeTokens
do {
    check(TokenFormat.short(999_950), "1M", "rounds up into the next unit")
    check(TokenFormat.short(999.6), "1k", "999.6")
    check(TokenFormat.short(.infinity), "—", "infinity")
    check(TokenFormat.short(.nan), "—", "nan")
    check(TokenFormat.short(-12_400), "-12.4k", "negative")
    check(TokenFormat.short(5e18), "5000000T", "huge")
}

print(failures == 0 ? "✓ LedgerKit checks passed" : "\(failures) check(s) failed")
exit(failures == 0 ? 0 : 1)
