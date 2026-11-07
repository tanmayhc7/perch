import AppKit
import ServiceManagement
import SwiftUI

/// Where the notch is on the screen, or where the pill goes on a Mac without one.
struct NotchGeometry: Equatable {
    var width: CGFloat
    var height: CGFloat
    var hasNotch: Bool
    /// The notch's horizontal centre, in screen coordinates.
    var midX: CGFloat
    /// The top of the screen, in screen coordinates.
    var top: CGFloat

    static let sample = NotchGeometry(width: 185, height: 32, hasNotch: true, midX: 640, top: 832)

    static func detect() -> (screen: NSScreen?, geometry: NotchGeometry) {
        // The built-in display's notch if there is one; otherwise the primary display (the one with the
        // menu bar). Not `NSScreen.main`: that follows keyboard focus from screen to screen.
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.screens.first
        guard let screen else { return (nil, .sample) }
        let f = screen.frame
        if screen.safeAreaInsets.top > 0, let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            let w = f.width - l.width - r.width
            return (screen, NotchGeometry(width: w, height: screen.safeAreaInsets.top, hasNotch: true,
                                          midX: f.minX + l.width + w / 2, top: f.maxY))
        }
        // No notch: a small pill in the middle of the menu bar.
        let bar = max(24, f.maxY - screen.visibleFrame.maxY)
        return (screen, NotchGeometry(width: 180, height: min(bar, 30), hasNotch: false, midX: f.midX, top: f.maxY))
    }
}

/// A message that slides out of the notch for a few seconds.
struct Toast: Identifiable, Equatable {
    let id = UUID()
    var symbol: String
    var tint: ToastTint = .accent
    var title: String
    var subtitle: String?
    var actionTitle: String?
    var action: (@MainActor () -> Void)?
    var seconds: Double = 5

    enum ToastTint { case accent, warning, danger, calm }

    static func == (a: Toast, b: Toast) -> Bool { a.id == b.id }
}

@MainActor @Observable
final class NotchState {
    enum Mode { case collapsed, expanded }

    var mode: Mode = .collapsed
    /// Files are being dragged near the notch.
    var dropMode = false
    /// Files are being dragged somewhere on screen: the closed notch says it takes drops.
    var dragHint = false
    var toast: Toast?
    private var queue: [Toast] = []
    /// Keeps the notch open (the prompt field has focus, a menu is open, an answer is showing).
    var pinned = false
    var geometry: NotchGeometry
    var showingAnswer = false

    /// Set by the controller: views call these instead of changing `mode` themselves.
    @ObservationIgnored var expandAction: () -> Void = {}
    @ObservationIgnored var collapseAction: () -> Void = {}
    @ObservationIgnored var focusPromptAction: () -> Void = {}

    init(geometry: NotchGeometry) { self.geometry = geometry }

    var isExpanded: Bool { mode == .expanded }

    func push(_ t: Toast) {
        // A burst (several sessions finishing at once) shouldn't keep the notch talking for a minute.
        if toast?.title == t.title || queue.contains(where: { $0.title == t.title }) { return }
        if toast == nil { show(t) } else if queue.count < 3 { queue.append(t) }
    }

    private func show(_ t: Toast) {
        toast = t
        let id = t.id
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(t.seconds))
            if self.toast?.id == id { self.dismissToast() }
        }
    }

    func dismissToast() {
        toast = nil
        if !queue.isEmpty {
            let next = queue.removeFirst()
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(450))
                self.show(next)
            }
        }
    }
}

enum Theme: String, CaseIterable, Identifiable {
    case ember, aurora, graphite
    var id: String { rawValue }
    var name: String { rawValue.capitalized }

    /// Main accent: rings, glows, the prompt spark.
    var accent: Color {
        switch self {
        case .ember: Color(red: 1.00, green: 0.55, blue: 0.32)
        case .aurora: Color(red: 0.36, green: 0.93, blue: 0.80)
        case .graphite: Color(white: 0.92)
        }
    }
    /// Second stop of every gradient.
    var accent2: Color {
        switch self {
        case .ember: Color(red: 1.00, green: 0.30, blue: 0.45)
        case .aurora: Color(red: 0.55, green: 0.45, blue: 1.00)
        case .graphite: Color(white: 0.55)
        }
    }
    var gradient: LinearGradient {
        LinearGradient(colors: [accent, accent2], startPoint: .leading, endPoint: .trailing)
    }
}

@MainActor @Observable
final class AppSettings {
    private let d: UserDefaults

    var theme: Theme { didSet { d.set(theme.rawValue, forKey: "theme") } }
    var hoverToExpand: Bool { didSet { d.set(hoverToExpand, forKey: "hoverToExpand") } }
    var finishAlerts: Bool { didSet { d.set(finishAlerts, forKey: "finishAlerts") } }
    var promptModel: String { didSet { d.set(promptModel, forKey: "promptModel") } }
    var launchAtLogin: Bool {
        didSet {
            guard !syncingLogin, persist else { return }
            do {
                if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch { NSLog("Perch: launch at login: \(error)") }
            // Registration can fail (an app run from Downloads or a translocated copy): show the real state.
            let actual = SMAppService.mainApp.status == .enabled
            if actual != launchAtLogin { syncingLogin = true; launchAtLogin = actual; syncingLogin = false }
        }
    }
    @ObservationIgnored private var syncingLogin = false
    private let persist: Bool

    /// `persist: false` (snapshots) keeps changes in memory only.
    init(persist: Bool = true) {
        self.persist = persist
        d = persist ? .standard : UserDefaults(suiteName: "perch.snapshots")!
        d.register(defaults: ["theme": Theme.ember.rawValue, "hoverToExpand": true, "finishAlerts": true, "promptModel": "haiku"])
        theme = Theme(rawValue: d.string(forKey: "theme") ?? "") ?? .ember
        hoverToExpand = d.bool(forKey: "hoverToExpand")
        finishAlerts = d.bool(forKey: "finishAlerts")
        let model = d.string(forKey: "promptModel") ?? "haiku"
        promptModel = PromptModel.models.contains { $0.id == model } ? model : "haiku"
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
