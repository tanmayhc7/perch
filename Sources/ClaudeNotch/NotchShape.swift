import SwiftUI

/// The notch's outline: flat along the top edge of the screen, with small concave
/// "shoulders" that flow into the menu bar and rounded bottom corners.
/// `shoulder` is part of the width: the body is `width - 2 * shoulder` wide.
struct NotchShape: Shape {
    var shoulder: CGFloat
    var bottom: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(shoulder, bottom) }
        set { shoulder = newValue.first; bottom = newValue.second }
    }

    func path(in r: CGRect) -> Path {
        let s = min(shoulder, r.width / 4)
        let b = min(bottom, (r.width - 2 * s) / 2, r.height - s)
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + s, y: r.minY + s), control: CGPoint(x: r.minX + s, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + s, y: r.maxY - b))
        p.addCurve(to: CGPoint(x: r.minX + s + b, y: r.maxY),
                   control1: CGPoint(x: r.minX + s, y: r.maxY - b * 0.45),
                   control2: CGPoint(x: r.minX + s + b * 0.45, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - s - b, y: r.maxY))
        p.addCurve(to: CGPoint(x: r.maxX - s, y: r.maxY - b),
                   control1: CGPoint(x: r.maxX - s - b * 0.45, y: r.maxY),
                   control2: CGPoint(x: r.maxX - s, y: r.maxY - b * 0.45))
        p.addLine(to: CGPoint(x: r.maxX - s, y: r.minY + s))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - s, y: r.minY))
        p.closeSubpath()
        return p
    }
}

/// Every size the notch takes, in one place, so the controller's hit-testing
/// and the views agree.
@MainActor
enum NotchLayout {
    static let ear: CGFloat = 74
    static let expandedWidth: CGFloat = 712
    static let inset: CGFloat = 16
    static let tileHeight: CGFloat = 154
    static let promptHeight: CGFloat = 40
    static let shelfHeight: CGFloat = 62
    static let gap: CGFloat = 10

    static func shoulder(expanded: Bool) -> CGFloat { expanded ? 14 : 6 }

    static func hasEars(claude: ClaudeModel, timer: FocusTimer, calendar: CalendarModel, now: Date = Date()) -> Bool {
        claude.stats.isResponding || timer.phase != .idle || meetingSoon(calendar, now: now) != nil
    }

    /// The next meeting when it starts within 10 minutes (or is on now).
    static func meetingSoon(_ c: CalendarModel, now: Date = Date()) -> CalendarModel.Meeting? {
        guard let m = c.next, m.start.timeIntervalSince(now) <= 600, m.end > now else { return nil }
        return m
    }

    static func shapeSize(state: NotchState, claude: ClaudeModel, timer: FocusTimer, calendar: CalendarModel, shelf: ShelfModel) -> CGSize {
        let g = state.geometry
        let collapsedShoulder = shoulder(expanded: false)
        if state.isExpanded {
            var h = g.height + 6 + tileHeight + gap + promptHeight + 14
            if !shelf.items.isEmpty { h += gap + shelfHeight }
            return CGSize(width: expandedWidth, height: h)
        }
        let ears = hasEars(claude: claude, timer: timer, calendar: calendar)
        var w = g.width + 2 * collapsedShoulder + (ears ? 2 * ear : 0)
        var h = g.height
        if state.toast != nil {
            w = max(w, g.width + 2 * ear + 120)
            h += 50
        }
        return CGSize(width: w, height: h)
    }

    static func shapeSize(_ env: AppEnvironment) -> CGSize {
        shapeSize(state: env.state, claude: env.claude, timer: env.timer, calendar: env.calendar, shelf: env.shelf)
    }
}
