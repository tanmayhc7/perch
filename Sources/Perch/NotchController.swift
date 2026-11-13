import AppKit
import LedgerKit
import SwiftUI

/// A borderless panel that can take keyboard focus (for the prompt) without activating the app.
final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Owns the panel over the notch and decides when it expands, from where the mouse is.
@MainActor
final class NotchController {
    static let windowSize = CGSize(width: 820, height: 440)

    private let env: AppEnvironment
    private var panel: NotchPanel!
    private var monitors: [Any] = []
    private var dragTimer: Timer?
    private var dragChangeCount = 0
    private var collapseWork: DispatchWorkItem?
    private var swipe = CGPoint.zero
    private var swipeFired = false
    private var swipeIgnored = false
    private var screen: NSScreen?
    /// The app that was in front before the prompt took focus; it gets focus back on collapse.
    private var previousApp: NSRunningApplication?

    init(env: AppEnvironment) { self.env = env }

    func show() {
        let p = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar + 1
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.isMovable = false
        p.hidesOnDeactivate = false
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        env.state.expandAction = { [weak self] in self?.expand() }
        env.state.collapseAction = { [weak self] in self?.collapse() }
        env.state.focusPromptAction = { [weak self] in self?.focusPrompt() }
        let root = NotchRootView().notchEnvironment(env)
        let host = NSHostingView(rootView: root)
        host.sizingOptions = []
        p.contentView = host
        panel = p
        place()
        p.orderFrontRegardless()

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.place() }
        }
        // After sleep: re-place, close a notch that was left open, and refresh everything.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.place()
                if self.env.state.isExpanded { self.collapse(restoreFocus: false) }
                self.env.state.dragHint = false
                self.env.claude.refresh()
                self.env.calendar.reload()
            }
        }
        installMonitors()
        observeState()
        if ProcessInfo.processInfo.environment["PERCH_DEBUG"] == "1" { installDebugHooks() }
    }

    /// Development only (PERCH_DEBUG=1): drive the live notch and capture it without
    /// Screen Recording permission. `object` is "expand", "collapse", "drop", "toast", "ask:<question>" or "shot:<path.png>".
    private func installDebugHooks() {
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("perch.debug"), object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated {
                guard let self, let cmd = n.object as? String else { return }
                NSLog("Perch debug: \(cmd) (mode \(self.env.state.mode))")
                switch cmd {
                case "expand": self.expand(); self.env.state.pinned = true
                case "collapse": self.collapse()
                case "cancel": self.env.prompt.cancel()
                case "dnd-on": self.env.settings.focusDND = true; self.env.focus.enable()
                case "timerstop": self.env.timer.stop()
                case "quit": NSApp.terminate(nil)
                case _ where cmd.hasPrefix("timer:"): self.env.timer.start(minutes: Double(cmd.dropFirst(6)) ?? 1, label: "Focus")
                case "focusstate": NSLog("Perch focus: setup=\(self.env.focus.setup) active=\(self.env.focus.active) toast=\(self.env.state.toast?.title ?? "-") music=\(self.env.music.title ?? "-")/session=\(self.env.music.inSession)/playing=\(self.env.music.playing)/muted=\(self.env.music.muted)")
                case _ where cmd.hasPrefix("slide:"):
                    if cmd == "slide:next" { self.env.state.step(1, in: self.env.settings.slides) }
                    else if cmd == "slide:prev" { self.env.state.step(-1, in: self.env.settings.slides) }
                    else if let s = Slide(rawValue: String(cmd.dropFirst(6))) { self.env.state.slide = s }
                case _ where cmd.hasPrefix("widget:"):
                    // widget:links:off, widget:calendar:on
                    let parts = cmd.split(separator: ":")
                    if parts.count == 3, let w = Widget(rawValue: String(parts[1])) { self.env.settings.set(w, on: parts[2] == "on") }
                case "timerpause": self.env.timer.toggle()
                case "musicmute": self.env.music.toggleMute()
                case "musicstop": self.env.music.stopForSession()
                case "calendars":
                    let c = self.env.calendar
                    let line = "access=\(c.access.rawValue) hidden=\(c.hiddenCount) next=\(c.next?.title ?? "-") groups=\(c.groups.map { "\($0.title)[\($0.calendars.map { ($0.title) + (c.isShown($0.id) ? "+" : "-") }.joined(separator: ","))]" })\n"
                    // NSLog redacts dynamic strings in the unified log, so debug output goes to a file when asked.
                    if let path = ProcessInfo.processInfo.environment["PERCH_DEBUG_LOG"], let h = FileHandle(forWritingAtPath: path) ?? { FileManager.default.createFile(atPath: path, contents: nil); return FileHandle(forWritingAtPath: path) }() {
                        h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
                    }
                case _ where cmd.hasPrefix("calhide:"):
                    let title = String(cmd.dropFirst(8))
                    for g in self.env.calendar.groups { for cal in g.calendars where cal.title == title { self.env.calendar.setShown(cal.id, false) } }
                case _ where cmd.hasPrefix("calshow:"):
                    let title = String(cmd.dropFirst(8))
                    for g in self.env.calendar.groups { for cal in g.calendars where cal.title == title { self.env.calendar.setShown(cal.id, true) } }
                case "calall": self.env.calendar.showAll()
                case "claudemodel":
                    let st = self.env.claude.stats
                    let line = "model=\(st.model ?? "-") shown=\(st.model.map(Transcript.displayName) ?? "-") sessions=\(st.sessions.map { "\($0.project):\($0.state)" })\n"
                    if let path = ProcessInfo.processInfo.environment["PERCH_DEBUG_LOG"], let h = FileHandle(forWritingAtPath: path) ?? { FileManager.default.createFile(atPath: path, contents: nil); return FileHandle(forWritingAtPath: path) }() {
                        h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
                    }
                case "musicpage": self.env.music.debugState { NSLog("Perch music page: \($0)") }
                case _ where cmd.hasPrefix("page:"): self.env.media.selectedID = String(cmd.dropFirst(5))
                case "state":
                    let p = self.env.prompt
                    NSLog("Perch state: phase=\(p.phase) asked=\(p.asked.prefix(40)) answer=\(p.answer.prefix(120).replacingOccurrences(of: "\n", with: " ")) toast=\(self.env.state.toast?.title ?? "-") media=\(self.env.media.selectedID) \(self.env.media.players.map { "\($0.id):\($0.running)/\($0.playing)/\($0.title)/art=\($0.artwork != nil)" }) claude=\(self.env.claude.loaded)/\(TokenFormat.short(self.env.claude.stats.windowTokens))/\(self.env.claude.stats.windowText)")
                case "loading": self.env.claude.loaded = false; self.env.media.players.forEach { $0.loaded = false }; self.expand(); self.env.state.pinned = true
                case "draghint": self.env.state.dragHint.toggle()
                case "drop": self.expand(); self.env.state.pinned = true; self.env.state.dropMode = true
                case "toast":
                    self.env.state.push(Toast(symbol: "flame.fill", tint: .warning, title: "Burning 42k tokens/min", subtitle: "A lighter model (/model sonnet) costs much less"))
                case _ where cmd.hasPrefix("ask:"):
                    self.env.prompt.text = String(cmd.dropFirst(4))
                    self.env.prompt.send(model: self.env.settings.promptModel)
                default:
                    if cmd.hasPrefix("shot:"), let view = self.panel.contentView,
                       let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: String(cmd.dropFirst(5))))
                    }
                }
            }
        }
    }

    private func place() {
        let (s, g) = NotchGeometry.detect()
        screen = s
        env.state.geometry = g
        let size = Self.windowSize
        panel.setFrame(NSRect(x: g.midX - size.width / 2, y: g.top - size.height, width: size.width, height: size.height), display: true)
        // Display changes (wake, a monitor plugged in or out) can leave the panel off screen or behind.
        panel.orderFrontRegardless()
    }

    // MARK: Mouse

    private func installMonitors() {
        let moved: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: moved) { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseMoved() }
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: moved) { [weak self] e in
            MainActor.assumeIsolated { self?.mouseMoved() }
            return e
        } as Any)
        // A drag from another app: poll while the button is down, because a drag
        // session doesn't always deliver events to monitors.
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseDown() }
        } as Any)
        // Two fingers sideways on the open notch switch slides.
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
            MainActor.assumeIsolated { self?.scrolled(e) }
            return e
        } as Any)
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            // A click anywhere else closes the notch, even if the prompt is pinned.
            MainActor.assumeIsolated { self?.clickOutside() }
        } as Any)
    }

    /// A trackpad swipe: once it has travelled far enough sideways, move one slide, once per gesture.
    private func scrolled(_ e: NSEvent) {
        // Only fingers on the trackpad (not the glide after lifting, nor a mouse wheel).
        guard e.window === panel, env.state.isExpanded, !env.state.dropMode, env.prompt.phase == .idle,
              e.momentumPhase.isEmpty, !e.phase.isEmpty else { return }
        if e.phase.contains(.began) {
            swipe = .zero
            swipeFired = false
            // The music tile turns its own pages (Spotify, Apple Music, focus music).
            let p = CGPoint(x: e.locationInWindow.x, y: (panel.contentView?.bounds.height ?? 0) - e.locationInWindow.y)
            swipeIgnored = env.state.musicFrame.contains(p) && env.state.slide == .home
        }
        guard !swipeIgnored, !swipeFired else { return }
        // Follow the fingers whichever way "natural scrolling" is set.
        let dx = e.isDirectionInvertedFromDevice ? e.scrollingDeltaX : -e.scrollingDeltaX
        swipe.x += dx
        swipe.y += e.scrollingDeltaY
        if abs(swipe.x) > 45, abs(swipe.x) > abs(swipe.y) * 1.5 {
            swipeFired = true
            // Fingers to the left bring in the slide on the right.
            env.state.step(swipe.x < 0 ? 1 : -1, in: env.settings.slides)
        }
    }

    /// The shape's current rectangle in screen coordinates, plus some slack.
    private func activeRect(slack: CGFloat) -> NSRect {
        let g = env.state.geometry
        let size = NotchLayout.shapeSize(env)
        // +edge: the cursor resting against the top of the screen reports y == top exactly,
        // which NSRect.contains counts as outside.
        return NSRect(x: g.midX - size.width / 2 - slack, y: g.top - size.height - slack,
                      width: size.width + slack * 2, height: size.height + slack + Self.edge)
    }

    private var notchRect: NSRect {
        let g = env.state.geometry
        // A little wider and taller than the notch itself, so it's easy to hit.
        return NSRect(x: g.midX - g.width / 2 - 10, y: g.top - g.height - 6, width: g.width + 20, height: g.height + 6 + Self.edge)
    }

    /// Hit areas reach this far above the top of the screen (see `activeRect`).
    private static let edge: CGFloat = 4

    private func mouseMoved() {
        let loc = NSEvent.mouseLocation
        let st = env.state
        let inside = activeRect(slack: st.isExpanded ? 14 : 2).contains(loc) || notchRect.contains(loc)
        panel.ignoresMouseEvents = !inside && !st.dropMode

        if st.isExpanded {
            if inside || st.pinned || st.dropMode {
                collapseWork?.cancel(); collapseWork = nil
            } else if collapseWork == nil {
                let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.collapseIfOutside() } }
                collapseWork = w
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: w)
            }
        } else if env.settings.hoverToExpand, notchRect.contains(loc) || (st.toast != nil && inside) {
            // Open on the first event inside the notch: no hover delay.
            if debug { NSLog("timing hover: entered notch at y=%.1f (top %.1f)", loc.y, st.geometry.top) }
            expand()
        }
    }

    private func collapseIfOutside() {
        collapseWork = nil
        let st = env.state
        guard st.isExpanded, !st.pinned, !st.dropMode else { return }
        if !activeRect(slack: 14).contains(NSEvent.mouseLocation) { collapse() }
    }

    private let debug = ProcessInfo.processInfo.environment["PERCH_DEBUG"] == "1"

    func expand() {
        guard !env.state.isExpanded else { return }
        let t0 = CFAbsoluteTimeGetCurrent()
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        env.state.mode = .expanded
        env.state.dismissToast()
        panel.ignoresMouseEvents = false
        let t1 = CFAbsoluteTimeGetCurrent()
        env.shelf.pruneMissing()
        for p in env.media.players where p.running { p.refresh() }
        env.claude.refresh()
        // EventKit queries can take a while; run them after the first frame is on screen.
        DispatchQueue.main.async { [env] in env.calendar.reload() }
        let t2 = CFAbsoluteTimeGetCurrent()
        if debug {
            panel.contentView?.layoutSubtreeIfNeeded()
            panel.displayIfNeeded()
            let t3 = CFAbsoluteTimeGetCurrent()
            NSLog("timing expand: state %.1fms, refresh %.1fms, first layout+draw %.1fms", (t1 - t0) * 1000, (t2 - t1) * 1000, (t3 - t2) * 1000)
        }
    }

    func collapse() { collapse(restoreFocus: true) }

    /// `restoreFocus`: hand the keyboard back to the app that had it before the prompt.
    /// Not after a click somewhere else: that click already chose where focus goes.
    func collapse(restoreFocus: Bool) {
        env.state.mode = .collapsed
        env.state.pinned = false
        env.state.dropMode = false
        if panel.isKeyWindow {
            panel.makeFirstResponder(nil)
            panel.resignKey()
            if restoreFocus { previousApp?.activate() }
        }
        previousApp = nil
        panel.ignoresMouseEvents = !activeRect(slack: 2).contains(NSEvent.mouseLocation)
    }

    private func focusPrompt() {
        if !panel.isKeyWindow {
            let front = NSWorkspace.shared.frontmostApplication
            if front?.bundleIdentifier != Bundle.main.bundleIdentifier { previousApp = front }
            panel.makeKey()
        }
    }

    private func clickOutside() {
        guard env.state.isExpanded else { return }
        if !activeRect(slack: 14).contains(NSEvent.mouseLocation) {
            env.state.pinned = false
            collapse(restoreFocus: false)
        }
    }

    // MARK: Drag and drop

    private func mouseDown() {
        dragChangeCount = NSPasteboard(name: .drag).changeCount
        dragTimer?.invalidate()
        dragTimer = Timer.scheduledTimer(withTimeInterval: 1 / 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollDrag() }
        }
    }

    private func pollDrag() {
        let st = env.state
        if NSEvent.pressedMouseButtons & 1 == 0 {
            dragTimer?.invalidate(); dragTimer = nil
            st.dragHint = false
            // The drop (or a cancelled drag) is over.
            if st.dropMode {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.env.state.dropMode else { return }
                        self.env.state.dropMode = false
                        self.collapseIfOutside()
                    }
                }
            }
            return
        }
        let pb = NSPasteboard(name: .drag)
        guard pb.changeCount != dragChangeCount,
              pb.types?.contains(.fileURL) == true else { return }
        let loc = NSEvent.mouseLocation
        let g = st.geometry
        let depth = st.dropMode ? 300 : g.height + 90
        let zone = NSRect(x: g.midX - 280, y: g.top - depth, width: 560, height: depth + Self.edge)
        let near = zone.contains(loc)
        // A file drag is under way: tell people the notch takes drops.
        if !st.isExpanded, !near, !st.dragHint { st.dragHint = true }
        if near, !st.dropMode {
            st.dragHint = false
            st.dropMode = true
            expand()
            panel.ignoresMouseEvents = false
        } else if !near, st.dropMode {
            st.dropMode = false
            panel.ignoresMouseEvents = true
            collapse()
        }
    }

    // MARK: State

    private func observeState() {
        withObservationTracking {
            _ = env.state.mode
            _ = env.state.toast
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // Clicking the notch (a SwiftUI tap) can expand it without the hover path.
                    if self.env.state.isExpanded { self.panel.ignoresMouseEvents = false }
                    self.observeState()
                }
            }
        }
    }
}
