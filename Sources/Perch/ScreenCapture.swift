import AppKit
import CoreGraphics

/// The Screenshot and Record buttons on the Home slide. They run macOS's own `screencapture` tool, so the pictures and
/// recordings come out exactly as the system's shortcuts make them, and go where the system saves them (the folder set in
/// the Screenshot app, else the Desktop). macOS asks once for Screen Recording permission, the first time a button is used.
@MainActor @Observable
final class ScreenCapture {
    /// When the current recording started; nil when not recording.
    private(set) var recordingSince: Date?
    /// A screenshot selection is under way.
    private(set) var selecting = false
    var isRecording: Bool { recordingSince != nil }

    @ObservationIgnored var onAlert: ((Toast) -> Void)?
    /// Closes the notch, so it isn't in the picture.
    @ObservationIgnored var closeNotch: () -> Void = {}
    @ObservationIgnored private var process: Process?

    private static let tool = URL(fileURLWithPath: "/usr/sbin/screencapture")
    /// Development only (`capture:fake:` debug hook): a stand-in for `screencapture`, so the flow can be tested without
    /// Screen Recording permission.
    @ObservationIgnored var standIn: URL?

    /// Where macOS saves screenshots: the Screenshot app's folder setting, else the Desktop.
    static var saveFolder: URL {
        if let path = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location"), !path.isEmpty {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    /// "Screenshot 2026-11-19 at 10.31.22.png", the way macOS names them.
    static func fileName(_ kind: String, ext: String, at date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "\(kind) \(f.string(from: date)).\(ext)"
    }

    // MARK: Permission

    /// Screen Recording must be allowed, or macOS hands back a picture with only the wallpaper in it.
    /// Asks the first time; says how to allow it afterwards.
    private func allowed() -> Bool {
        if standIn != nil || CGPreflightScreenCaptureAccess() { return true }
        _ = CGRequestScreenCaptureAccess()
        onAlert?(Toast(symbol: "rectangle.dashed.badge.record", tint: .warning, title: "Allow screen recording for Perch",
                       subtitle: "Switch Perch on in Screen Recording, then reopen Perch and try again",
                       actionTitle: "Open", action: {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }, seconds: 12))
        return false
    }

    // MARK: Screenshot

    /// Opens the crosshair: drag for an area, Space for a window, Esc to cancel, hold Control to copy instead of save.
    /// `interactive: false` takes the whole screen (used by tests).
    func screenshot(interactive: Bool = true, to destination: URL? = nil) {
        guard process == nil, allowed() else { return }
        let file = destination ?? Self.saveFolder.appendingPathComponent(Self.fileName("Screenshot", ext: "png"))
        closeNotch()
        selecting = true
        Task {
            // Let the notch finish closing before the picture is taken.
            try? await Task.sleep(for: .milliseconds(450))
            run(arguments: (interactive ? ["-i"] : ["-x"]) + [file.path]) { [weak self] status, errors in
                guard let self else { return }
                self.selecting = false
                if FileManager.default.fileExists(atPath: file.path) {
                    self.saved("Screenshot saved", file)
                } else if status == 0 {
                    // Control held: it went to the clipboard.
                    self.onAlert?(Toast(symbol: "doc.on.clipboard.fill", tint: .calm, title: "Screenshot copied", subtitle: "It's on your clipboard"))
                } else if !errors.isEmpty {
                    self.onAlert?(Toast(symbol: "exclamationmark.triangle.fill", tint: .warning, title: "Couldn't take the screenshot",
                                        subtitle: String(errors.prefix(80))))
                }
                // Otherwise it was cancelled with Esc: nothing to say.
            }
        }
    }

    // MARK: Recording

    func toggleRecording() { isRecording ? stopRecording() : startRecording() }

    /// Records the main display until stopped. The system's recording indicator shows in the menu bar meanwhile.
    func startRecording(to destination: URL? = nil) {
        guard process == nil, allowed() else { return }
        let file = destination ?? Self.saveFolder.appendingPathComponent(Self.fileName("Screen Recording", ext: "mov"))
        closeNotch()
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            recordingSince = Date()
            run(arguments: ["-v", "-x", file.path]) { [weak self] status, errors in
                guard let self else { return }
                self.recordingSince = nil
                if FileManager.default.fileExists(atPath: file.path) {
                    self.saved("Recording saved", file)
                } else {
                    self.onAlert?(Toast(symbol: "exclamationmark.triangle.fill", tint: .warning, title: "Couldn't record the screen",
                                        subtitle: errors.isEmpty ? "Nothing was saved" : String(errors.prefix(80))))
                }
            }
        }
    }

    /// Ends the recording the way Control-C does, which lets the tool finish the file.
    func stopRecording() {
        guard isRecording, let p = process, p.isRunning else { return }
        p.interrupt()
    }

    /// Perch is quitting: finish a recording in progress so its file isn't left unplayable.
    func stopBeforeQuit() {
        guard let p = process, p.isRunning else { return }
        p.interrupt()
        let deadline = Date().addingTimeInterval(3)
        while p.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
    }

    // MARK: Plumbing

    private func saved(_ title: String, _ file: URL) {
        onAlert?(Toast(symbol: "checkmark.circle.fill", tint: .calm, title: title, subtitle: file.lastPathComponent,
                       actionTitle: "Show", action: { NSWorkspace.shared.activateFileViewerSelecting([file]) }, seconds: 8))
    }

    /// Runs `screencapture`; `done` runs on the main actor with its exit status and what it printed to stderr.
    private func run(arguments: [String], done: @escaping (Int32, String) -> Void) {
        let p = Process()
        p.executableURL = standIn ?? Self.tool
        p.arguments = arguments
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        p.terminationHandler = { [weak self] proc in
            let text = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.process === proc else { return }
                    self.process = nil
                    done(proc.terminationStatus, text)
                }
            }
        }
        do {
            try p.run()
            process = p
        } catch {
            selecting = false
            recordingSince = nil
            onAlert?(Toast(symbol: "exclamationmark.triangle.fill", tint: .warning, title: "Couldn't start the capture", subtitle: error.localizedDescription))
        }
    }
}
