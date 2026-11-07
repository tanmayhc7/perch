import AppKit

/// Turns on Do Not Disturb while the focus timer runs, then puts back whatever Focus was on before.
///
/// macOS has no public API for Focus, so this goes through two shortcuts that Perch ships
/// (built by scripts/focus-shortcut.py) and runs with the `shortcuts` command:
///   "Perch Focus" <name>  prints the Focus that was on, then turns <name> on
///   "Perch Focus Off"     prints the Focus that was on, then turns Do Not Disturb off
/// Shortcuts can't end a Focus at a set time when the shortcut is generated, so Perch ends it
/// itself, and remembers the session on disk so a quit, crash or sleep can't leave DND stuck on.
@MainActor @Observable
final class FocusLink {
    enum Setup: Equatable { case unknown, missing, duplicate, ready }

    static let onShortcut = "Perch Focus"
    static let offShortcut = "Perch Focus Off"
    static let dnd = "Do Not Disturb"

    private(set) var setup: Setup = .unknown
    /// Shortcuts not yet in the Shortcuts app.
    @ObservationIgnored private var missing: [String] = [FocusLink.onShortcut, FocusLink.offShortcut]
    /// Do Not Disturb is on because of the timer.
    private(set) var active = false

    @ObservationIgnored var onAlert: ((Toast) -> Void)?
    @ObservationIgnored var isEnabled: () -> Bool = { false }
    @ObservationIgnored private let queue = DispatchQueue(label: "perch.focus", qos: .userInitiated)
    @ObservationIgnored private let defaults: UserDefaults

    /// What to restore, saved while DND is on: survives a quit or crash.
    private struct Session: Codable { var previous: String; var endsAt: Date }

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private var session: Session? {
        get { defaults.data(forKey: "focusSession").flatMap { try? JSONDecoder().decode(Session.self, from: $0) } }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) { defaults.set(data, forKey: "focusSession") }
            else { defaults.removeObject(forKey: "focusSession") }
            active = newValue != nil
        }
    }

    func start() {
        active = session != nil
        // A session left over from before (Perch quit or crashed mid-timer): the timer is gone, so end it.
        if session != nil { finish() }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let s = self.session, s.endsAt <= Date() else { return }
                self.finish()
            }
        }
        if isEnabled() { checkSetup() }
    }

    // MARK: Setup

    /// Looks for the two shortcuts. Two shortcuts with the same name make `shortcuts run` fail, so that's its own state.
    func checkSetup(then: ((Setup) -> Void)? = nil) {
        queue.async {
            let names = Self.run(["list"])?.output.split(separator: "\n").map(String.init) ?? []
            let counts = [Self.onShortcut, Self.offShortcut].map { n in (n, names.filter { $0 == n }.count) }
            let missing = counts.filter { $0.1 == 0 }.map(\.0)
            let result: Setup = !missing.isEmpty ? .missing : (counts.contains { $0.1 > 1 } ? .duplicate : .ready)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.missing = missing
                    self.setup = result
                    then?(result)
                }
            }
        }
    }

    /// Opens the shortcuts in the Shortcuts app, where the person clicks Add Shortcut on each.
    func install() {
        // Only the missing ones: importing one that's already there makes a second copy.
        let names = missing.isEmpty ? [Self.onShortcut, Self.offShortcut] : missing
        let files = names.compactMap(Self.shortcutFile)
        guard files.count == names.count else {
            onAlert?(Toast(symbol: "exclamationmark.triangle.fill", tint: .warning, title: "Focus shortcuts are missing from Perch",
                           subtitle: "Reinstall Perch from the latest release"))
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        for (i, f) in files.enumerated() {
            // One after another: Shortcuts shows one import window at a time.
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 1.5) { NSWorkspace.shared.open(f) }
        }
        let list = names.map { "\"\($0)\"" }.joined(separator: " and ")
        onAlert?(Toast(symbol: "moon.fill", tint: .accent, title: names.count > 1 ? "Add the shortcuts in Shortcuts" : "Add the shortcut in Shortcuts",
                       subtitle: "Click Add Shortcut on \(list)", seconds: 10))
        // Check back once they've had time to click.
        for delay in [10.0, 25.0, 60.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.setup != .ready else { return }
                self.checkSetup()
            }
        }
    }

    /// The bundled .shortcut file (in the app's Resources, or the repo's when run with `swift run`).
    static func shortcutFile(_ name: String) -> URL? {
        if let url = Bundle.main.url(forResource: name, withExtension: "shortcut") { return url }
        var dir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<5 {
            let candidate = dir.appendingPathComponent("Resources/\(name).shortcut")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            dir.deleteLastPathComponent()
        }
        return nil
    }

    // MARK: Timer hooks

    /// The timer started: turn on Do Not Disturb, remembering what was on.
    func begin(endsAt: Date) {
        guard isEnabled() else { return }
        if var s = session {
            // Restarted while DND is already ours: keep the original Focus to restore.
            s.endsAt = endsAt
            session = s
            return
        }
        // Save first, so a crash between here and the shortcut still ends it.
        session = Session(previous: "", endsAt: endsAt)
        queue.async {
            let r = Self.run(["run", Self.onShortcut, "-i"], input: Self.dnd)
            NSLog("Perch focus: DND on; was [\(r?.output ?? "no answer")] ok=\(r?.ok ?? false) \(r?.error ?? "")")
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let r, r.ok else { return self.failed(r, doing: "turn on Do Not Disturb", clear: true) }
                    // What was on before ("" for nothing). If that was DND itself, it's put back on afterwards.
                    if var s = self.session { s.previous = r.output; self.session = s }
                }
            }
        }
    }

    /// The timer finished or was stopped: turn Do Not Disturb off and put back the previous Focus.
    /// If the person changed Focus themselves meanwhile, theirs is left alone.
    func finish() {
        guard let s = session else { return }
        session = nil
        queue.async {
            let r = Self.run(["run", Self.offShortcut])
            var restore: RunResult?
            // Only if DND was still on (ours). An empty previous means no Focus was on.
            if let r, r.ok, r.output == Self.dnd, !s.previous.isEmpty {
                restore = Self.run(["run", Self.onShortcut, "-i"], input: s.previous)
            }
            NSLog("Perch focus: DND off; was [\(r?.output ?? "no answer")] ok=\(r?.ok ?? false); restored [\(restore == nil ? "-" : s.previous)]")
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let r, r.ok else { return self.failed(r, doing: "turn off Do Not Disturb", clear: false) }
                    if let restore, !restore.ok { self.failed(restore, doing: "turn \(s.previous) back on", clear: false) }
                }
            }
        }
    }

    /// Perch is quitting: end the session now, on this thread, so DND isn't left on with nothing to end it.
    /// Bounded so a hung Shortcuts can't stall the quit for long; the saved session catches anything missed.
    func finishBeforeQuit() {
        guard let s = session else { return }
        guard let r = Self.run(["run", Self.offShortcut], timeout: 4), r.ok else { return NSLog("Perch focus: quit: DND off failed") }
        var restored = "-"
        if r.output == Self.dnd, !s.previous.isEmpty {
            restored = Self.run(["run", Self.onShortcut, "-i"], input: s.previous, timeout: 4)?.ok == true ? s.previous : "failed"
        }
        NSLog("Perch focus: quit: DND off; was [\(r.output)]; restored [\(restored)]")
        session = nil
    }

    /// The settings toggle: make sure the shortcuts are there, offering to add them if not.
    func enable() {
        checkSetup { [weak self] setup in
            guard let self else { return }
            switch setup {
            case .missing: self.install()
            case .duplicate:
                self.onAlert?(Toast(symbol: "exclamationmark.triangle.fill", tint: .warning, title: "Two shortcuts share a Perch name",
                                    subtitle: "Delete the extra \"Perch Focus\" in Shortcuts", seconds: 10))
            case .ready, .unknown: break
            }
        }
    }

    private func failed(_ r: RunResult?, doing what: String, clear: Bool) {
        if clear { session = nil }
        let detail = r?.error.isEmpty == false ? r!.error : (r == nil ? "Shortcuts didn't answer" : "Shortcuts reported an error")
        if detail.contains("Couldn’t find shortcut") || detail.contains("Couldn't find shortcut") { checkSetup() }
        onAlert?(Toast(symbol: "moon.zzz.fill", tint: .warning, title: "Couldn't \(what)", subtitle: String(detail.prefix(80)), seconds: 8))
    }

    // MARK: Running shortcuts

    struct RunResult { var ok: Bool; var output: String; var error: String }

    /// `shortcuts <args> [input file]`, with a time limit and one retry, so a slow or stuck run can't hold up the timer.
    /// stdin must be closed: with it open, `shortcuts run` waits to read input from it and never finishes.
    nonisolated static func run(_ args: [String], input: String? = nil, timeout: TimeInterval = 10) -> RunResult? {
        if let r = runOnce(args, input: input, timeout: timeout) { return r }
        return runOnce(args, input: input, timeout: timeout)
    }

    nonisolated private static func runOnce(_ args: [String], input: String?, timeout: TimeInterval) -> RunResult? {
        var args = args
        var inputFile: URL?
        if let input {
            let f = FileManager.default.temporaryDirectory.appendingPathComponent("perch-focus-\(UUID().uuidString).txt")
            guard (try? input.write(to: f, atomically: true, encoding: .utf8)) != nil else { return nil }
            inputFile = f
            args.append(f.path)
        }
        defer { if let inputFile { try? FileManager.default.removeItem(at: inputFile) } }
        if args.first == "run" { args += ["-o", "-"] }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        // Read while it runs so a large listing can't fill the pipe and stall it.
        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        group.enter(); DispatchQueue.global().async { outData = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter(); DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning, Date() < deadline { usleep(20_000) }
        if p.isRunning { p.terminate(); return nil }
        _ = group.wait(timeout: .now() + 1)
        let o = String(decoding: outData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let e = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        // Errors come back as "Error: …" on either stream, with exit status 1.
        let failed = p.terminationStatus != 0 || o.hasPrefix("Error:")
        return RunResult(ok: !failed, output: failed ? "" : o, error: failed ? (e.isEmpty ? o : e) : "")
    }
}
