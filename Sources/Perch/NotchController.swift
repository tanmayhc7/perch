import AppKit
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
                case "loading": self.env.claude.loaded = false; self.env.spotify.loaded = false; self.expand(); self.env.state.pinned = true
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
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            // A click anywhere else closes the notch, even if the prompt is pinned.
            MainActor.assumeIsolated { self?.clickOutside() }
        } as Any)
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
        if env.spotify.running { env.spotify.refresh() }
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

    func collapse() {
        env.state.mode = .collapsed
        env.state.pinned = false
        env.state.dropMode = false
        if panel.isKeyWindow {
            panel.makeFirstResponder(nil)
            panel.resignKey()
            previousApp?.activate()
            previousApp = nil
        }
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
            collapse()
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
