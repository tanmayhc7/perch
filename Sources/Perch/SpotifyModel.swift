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

    /// Spotify has answered at least once since it was found running.
    var loaded = false

    var hasTrack: Bool { running && !title.isEmpty }

    @ObservationIgnored private var artworkURL = ""
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let queue = DispatchQueue(label: "perch.spotify", qos: .userInitiated)
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
            loaded = false
            clearTrack()
        }
    }

    private func clearTrack() {
        playing = false
        title = ""
        artist = ""
        album = ""
        duration = 0
        artwork = nil
        artworkURL = ""
    }

    /// A read script is under way. A busy Spotify can hold one for a long time; don't queue more behind it.
    @ObservationIgnored private var reading = false

    /// Fields are separated by ASCII 31 (unit separator), which can't appear in a track name the way a line break can.
    /// The `is running` check matters: a `tell` to an app that quit a moment ago would relaunch it.
    private static let readScript = """
    if application id "com.spotify.client" is running then
        with timeout of 4 seconds
        tell application id "com.spotify.client"
            set sep to character id 31
            set pState to player state as string
            if pState is "stopped" then return pState
            set tr to current track
            return pState & sep & (name of tr) & sep & (artist of tr) & sep & (album of tr) & sep & (artwork url of tr) & sep & ((duration of tr) as string) & sep & ((player position) as string)
        end tell
        end timeout
    end if
    return "closed"
    """

    func refresh() {
        guard running else { return }
        guard !reading else { return }
        reading = true
        run(Self.readScript) { [weak self] out in
            guard let self else { return }
            self.reading = false
            self.loaded = true
            guard let out else { return }
            if out == "stopped" || out == "closed" { self.clearTrack(); return }
            let p = out.components(separatedBy: "\u{1F}")
            guard p.count >= 7 else { return }
            self.playing = p[0] == "playing"
            self.title = p[1]
            self.artist = p[2]
            self.album = p[3]
            let d = (Double(p[5]) ?? 0) / 1000
            self.duration = d.isFinite && d > 0 ? d : 0
            let pos = Double(p[6].replacingOccurrences(of: ",", with: ".")) ?? 0
            self.positionAtRead = pos.isFinite && pos > 0 ? pos : 0
            self.positionAt = Date()
            if p[4] != self.artworkURL { self.loadArtwork(p[4]) }
        }
    }

    func playPause() {
        guard running else { return }
        // Keep the progress bar where it is: bank the time played so far before flipping state.
        positionAtRead = position(at: Date())
        positionAt = Date()
        playing.toggle()
        command("playpause")
    }
    func next() { command("next track") }
    func previous() { command("previous track") }

    func openSpotify() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }

    private func command(_ c: String) {
        guard running else { return }
        run("if application id \"com.spotify.client\" is running then tell application id \"com.spotify.client\" to \(c)") { [weak self] _ in
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
            if let err { NSLog("Perch: Spotify script error \(err[NSAppleScript.errorNumber] ?? "?"): \(err[NSAppleScript.errorMessage] ?? "")") }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.permissionDenied = denied
                    done(err == nil ? out : nil)
                }
            }
        }
    }
}
