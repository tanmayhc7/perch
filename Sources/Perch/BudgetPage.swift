import AppKit
import LedgerKit
import SwiftUI

/// The Claude tile's second page: the options of token-meter's all-sessions budget (a token limit, a dollar limit and
/// the window they count over), written to the shared budget file that every Claude Code session reads.
struct BudgetPage: View {
    @Environment(ClaudeModel.self) private var claude
    @Environment(AppSettings.self) private var settings

    private let tokenPresets: [Double] = [1e6, 2e6, 5e6, 10e6]
    private let dollarPresets: [Double] = [5, 10, 20, 50]
    private let windowPresets: [Double] = [5, 24, 168]

    var body: some View {
        let b = claude.stats.budget
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("BUDGET").label().help("The budget shared by every Claude Code session (token-meter's /token-budget all)")
                Spacer(minLength: 0)
                Text(summary(b)).font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
            }
            .frame(height: 16)
            row("TOKENS", presets: tokenPresets, label: { TokenFormat.short($0) }, current: b?.tokens,
                help: "A token limit for every Claude Code session together. Click the lit one to remove it.",
                custom: { claude.promptBudget(.tokens) }) { v in claude.setBudget(tokens: v == b?.tokens ? .remove : .set(v)) }
            row("DOLLARS", presets: dollarPresets, label: { "$" + String(format: "%g", $0) }, current: b?.usd,
                help: "A dollar limit, at API list prices. Click the lit one to remove it.",
                custom: { claude.promptBudget(.dollars) }) { v in claude.setBudget(usd: v == b?.usd ? .remove : .set(v)) }
            row("WINDOW", presets: windowPresets, label: { windowName($0) }, current: b?.windowHours,
                help: "How far back usage counts: the budget is a rolling window.",
                custom: { claude.promptBudget(.window) }) { v in claude.setBudget(windowHours: v) }
            Spacer(minLength: 0)
            // The one place to clear it. Shown dimmed when there is nothing to clear.
            let hasBudget = b?.tokens != nil || b?.usd != nil
            Button { claude.confirmClearBudget() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 10))
                    Text("Clear budget").font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(.white.opacity(hasBudget ? 0.9 : 0.35))
                .padding(.horizontal, 10).frame(height: 24)
                .background(Capsule().fill(.white.opacity(hasBudget ? 0.12 : 0.05)))
            }
            .buttonStyle(PressScale())
            .disabled(!hasBudget)
            .help(hasBudget ? "Remove the budget for every Claude Code session (asks first; the next notice can undo it)" : "No budget is set")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.trailing, 4)
    }

    private func windowName(_ h: Double) -> String {
        h >= 48 && h.truncatingRemainder(dividingBy: 24) == 0 ? "\(Int(h / 24))d" : (h == h.rounded() ? "\(Int(h))h" : String(format: "%.1fh", h))
    }

    private func summary(_ b: LedgerBudget?) -> String {
        guard let b else { return "No budget" }
        let parts = [b.tokens.map { TokenFormat.short($0) }, b.usd.map { "$" + String(format: "%g", $0) }].compactMap { $0 }
        guard !parts.isEmpty else { return "No budget · \(b.windowText)" }
        // What's left, then the limits: "54% left · 5M + $20 · 24h".
        let left = claude.stats.budgetPercentLeft.map { "\($0)% left · " } ?? ""
        return left + parts.joined(separator: " + ") + " · \(b.windowText)"
    }

    /// One line: a label, the presets as chips, and a chip for a value of your own (shown lit when the current value isn't a preset).
    private func row(_ title: String, presets: [Double], label: @escaping (Double) -> String, current: Double?, help: String,
                     custom: @escaping () -> Void, pick: @escaping (Double) -> Void) -> some View {
        let isCustom = current != nil && !presets.contains { abs($0 - current!) < 1e-9 }
        return HStack(spacing: 4) {
            Text(title).label().frame(width: 52, alignment: .leading)
            ForEach(presets, id: \.self) { v in
                Chip(text: label(v), lit: current.map { abs($0 - v) < 1e-9 } ?? false, theme: settings.theme) { pick(v) }
            }
            if isCustom, let c = current { Chip(text: label(c), lit: true, theme: settings.theme) { custom() } }
            Chip(text: "…", lit: false, theme: settings.theme, help: "Another value") { custom() }
            Spacer(minLength: 0)
        }
        .frame(height: 26)
        .help(help)
    }
}

/// A small selectable pill.
private struct Chip: View {
    var text: String
    var lit: Bool
    var theme: Theme
    var help = ""
    var action: () -> Void
    private let _hover = State(initialValue: false)

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 10.5, weight: .semibold, design: .rounded)).lineLimit(1)
                .foregroundStyle(lit ? Color.black : .white.opacity(0.85))
                .padding(.horizontal, 7).frame(height: 22)
                .background(Capsule().fill(lit ? AnyShapeStyle(theme.gradient) : AnyShapeStyle(.white.opacity(_hover.wrappedValue ? 0.16 : 0.09))))
        }
        .buttonStyle(PressScale())
        .onHover { h in _hover.wrappedValue = h }
        .help(help)
    }
}
