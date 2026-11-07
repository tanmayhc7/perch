import AppKit

/// Spotify's now-playing info and controls, through its AppleScript interface.
/// Never launches Spotify on its own: scripts only run while Spotify is open.
@MainActor @Observable
final class SpotifyModel {
    static let bundleID = "com.spotify.client"

    var installed = false
    var running = false
    var playing = false
    var title = ""
    var artist = ""
    var album = ""
    var artwork: NSImage?
    /// Seconds.
    var duration: Double = 0
    /// Player position when `positionAt` was read; see `position(at:)`.
    var positionAtRead: Double = 0
    var positionAt = Date()
    /// macOS refused the Apple Events permission.
    var permissionDenied = false

    var hasTrack: Bool { running && !title.isEmpty }

    @ObservationIgnored private var artworkURL = ""
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let queue = DispatchQueue(label: "claude-notch.spotify", qos: .userInitiated)
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    func position(at date: Date) -> Double {
        guard duration > 0 else { return 0 }
        return min(duration, positionAtRead + (playing ? date.timeIntervalSince(positionAt) : 0))
    }

    func start() {
        installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) != nil
        updateRunning()
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == SpotifyModel.bundleID else { return }
                MainActor.assumeIsolated { self?.updateRunning() }
            })
        }
        // Spotify posts this on every play, pause and track change.
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.spotify.client.PlaybackStateChanged"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { if self?.running == true { self?.refresh() } }
        }
    }

    private func updateRunning() {
        running = !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty
        if running {
            installed = true
            refresh()
        } else {
            playing = false
            title = ""
            artist = ""
            artwork = nil
            artworkURL = ""
        }
    }

    private static let readScript = """
    tell application id "com.spotify.client"
        set pState to player state as string
        set tr to current track
        return pState & linefeed & (name of tr) & linefeed & (artist of tr) & linefeed & (album of tr) & linefeed & (artwork url of tr) & linefeed & ((duration of tr) as string) & linefeed & ((player position) as string)
    end tell
    """

    func refresh() {
        guard running else { return }
        run(Self.readScript) { [weak self] out in
            guard let self, let out else { return }
            let p = out.components(separatedBy: "\n")
            guard p.count >= 7 else { return }
            self.playing = p[0] == "playing"
            self.title = p[1]
            self.artist = p[2]
            self.album = p[3]
            self.duration = (Double(p[5]) ?? 0) / 1000
            self.positionAtRead = Double(p[6].replacingOccurrences(of: ",", with: ".")) ?? 0
            self.positionAt = Date()
            if p[4] != self.artworkURL { self.loadArtwork(p[4]) }
        }
    }

    func playPause() { command("playpause"); playing.toggle(); positionAt = Date() }
    func next() { command("next track") }
    func previous() { command("previous track") }

    func openSpotify() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }

    private func command(_ c: String) {
        guard running else { return }
        run("tell application id \"com.spotify.client\" to \(c)") { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                self?.refresh()
            }
        }
    }

    private func loadArtwork(_ s: String) {
        artworkURL = s
        guard let url = URL(string: s), url.scheme == "https" else { artwork = nil; return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            let img = data.flatMap(NSImage.init(data:))
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if self.artworkURL == s { self.artwork = img }
                }
            }
        }.resume()
    }

    /// Runs AppleScript off the main thread (scripts can block while Spotify is busy).
    private func run(_ source: String, done: @escaping @MainActor (String?) -> Void) {
        queue.async {
            var err: NSDictionary?
            let result = NSAppleScript(source: source)?.executeAndReturnError(&err)
            let denied = (err?[NSAppleScript.errorNumber] as? Int) == -1743
            let out = result?.stringValue
            if let err { NSLog("claude-notch: Spotify script error \(err[NSAppleScript.errorNumber] ?? "?"): \(err[NSAppleScript.errorMessage] ?? "")") }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.permissionDenied = denied
                    done(err == nil ? out : nil)
                }
            }
        }
    }
}
