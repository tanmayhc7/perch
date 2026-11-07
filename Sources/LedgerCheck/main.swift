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

print(failures == 0 ? "✓ LedgerKit checks passed" : "\(failures) check(s) failed")
exit(failures == 0 ? 0 : 1)
