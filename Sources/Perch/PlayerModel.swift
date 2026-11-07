import AppKit

/// One music app's now-playing info and controls, through its AppleScript interface.
/// Never launches the app on its own: scripts only run while it is open.
@MainActor @Observable
final class PlayerModel: Identifiable {
    /// What differs between Spotify and Apple Music.
    struct Source: Sendable {
        var id: String
        var name: String
        var bundleID: String
        /// Posted by the app on every play, pause and track change.
        var notification: String
        /// Spotify reports durations in milliseconds, Music in seconds.
        var durationScale: Double
        /// Spotify's 5th field is an artwork URL; Music's is the track's ID and art comes from a second script.
        var artworkFromURL: Bool

        static let spotify = Source(id: "spotify", name: "Spotify", bundleID: "com.spotify.client",
                                    notification: "com.spotify.client.PlaybackStateChanged", durationScale: 1000, artworkFromURL: true)
        static let music = Source(id: "music", name: "Apple Music", bundleID: "com.apple.Music",
                                  notification: "com.apple.Music.playerInfo", durationScale: 1, artworkFromURL: false)
    }

    let source: Source
    nonisolated var id: String { source.id }

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

    /// The app has answered at least once since it was found running.
    var loaded = false

    var hasTrack: Bool { running && !title.isEmpty }

    /// Called when playback starts (not on every refresh while playing), so the tile can show this app.
    @ObservationIgnored var onStartedPlaying: (() -> Void)?
    @ObservationIgnored private var artworkKey = ""
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let queue: DispatchQueue
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// A read script is under way. A busy app can hold one for a long time; don't queue more behind it.
    @ObservationIgnored private var reading = false

    init(source: Source) {
        self.source = source
        queue = DispatchQueue(label: "perch.player.\(source.id)", qos: .userInitiated)
    }

    func position(at date: Date) -> Double {
        guard duration > 0 else { return 0 }
        return min(duration, positionAtRead + (playing ? date.timeIntervalSince(positionAt) : 0))
    }

    func start() {
        installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: source.bundleID) != nil
        updateRunning()
        let ws = NSWorkspace.shared.notificationCenter
        let bundleID = source.bundleID
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == bundleID else { return }
                MainActor.assumeIsolated { self?.updateRunning() }
            })
        }
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(source.notification), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { if self?.running == true { self?.refresh() } }
        }
    }

    private func updateRunning() {
        running = Self.isLive(source.bundleID)
        if running {
            quietUntil = .distantPast
            installed = true
            refresh()
        } else {
            quietUntil = Date().addingTimeInterval(8)
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
        artworkKey = ""
    }

    /// Fields are separated by ASCII 31 (unit separator), which can't appear in a track name the way a line break can.
    /// The `is running` check matters: a `tell` to an app that quit a moment ago would relaunch it.
    /// Duration, album and artwork key are optional: radio streams may not have them.
    private var readScript: String {
        let key = source.artworkFromURL ? "artwork url of tr" : "persistent ID of tr"
        return """
        if application id "\(source.bundleID)" is running then
            with timeout of 4 seconds
            tell application id "\(source.bundleID)"
                set sep to character id 31
                set pState to player state as string
                if pState is "stopped" then return pState
                set tr to current track
                set k to ""
                try
                    set k to (\(key)) as string
                end try
                set d to 0
                try
                    set d to duration of tr
                end try
                set al to ""
                try
                    set al to album of tr
                end try
                return pState & sep & (name of tr) & sep & (artist of tr) & sep & al & sep & k & sep & (d as string) & sep & ((player position) as string)
            end tell
            end timeout
        end if
        return "closed"
        """
    }

    func refresh() {
        guard running, !reading else { return }
        reading = true
        run(readScript) { [weak self] result in
            guard let self else { return }
            self.reading = false
            self.loaded = true
            guard let out = result?.stringValue else { return }
            if out == "stopped" || out == "closed" { self.clearTrack(); return }
            let p = out.components(separatedBy: "\u{1F}")
            guard p.count >= 7 else { return }
            let wasPlaying = self.playing
            self.playing = p[0] == "playing"
            self.title = p[1]
            self.artist = p[2]
            self.album = p[3]
            let d = Self.number(p[5]) / self.source.durationScale
            self.duration = d.isFinite && d > 0 ? d : 0
            let pos = Self.number(p[6])
            self.positionAtRead = pos.isFinite && pos > 0 ? pos : 0
            self.positionAt = Date()
            if p[4] != self.artworkKey { self.loadArtwork(p[4]) }
            if self.playing && !wasPlaying { self.onStartedPlaying?() }
        }
    }

    /// AppleScript numbers come back in the system locale ("215,5" in much of Europe).
    private static func number(_ s: String) -> Double {
        Double(s.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)) ?? 0
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

    func openApp() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: source.bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }

    private func command(_ c: String) {
        guard running else { return }
        run("if application id \"\(source.bundleID)\" is running then tell application id \"\(source.bundleID)\" to \(c)") { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                self?.refresh()
            }
        }
    }

    private func loadArtwork(_ key: String) {
        artworkKey = key
        if source.artworkFromURL {
            guard let url = URL(string: key), url.scheme == "https" else { artwork = nil; return }
            URLSession.shared.dataTask(with: url) { data, _, _ in
                let img = data.flatMap(NSImage.init(data:))
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { if self.artworkKey == key { self.artwork = img } }
                }
            }.resume()
        } else {
            // Music hands over the picture itself. Streamed tracks sometimes have none.
            let script = """
            if application id "\(source.bundleID)" is running then
                with timeout of 4 seconds
                tell application id "\(source.bundleID)"
                    try
                        return raw data of artwork 1 of current track
                    on error
                        try
                            return data of artwork 1 of current track
                        end try
                    end try
                end tell
                end timeout
            end if
            return ""
            """
            run(script) { [weak self] result in
                guard let self, self.artworkKey == key else { return }
                let data = result?.data ?? Data()
                self.artwork = data.count > 32 ? NSImage(data: data) : nil
            }
        }
    }

    /// No scripts until then: the app just quit or its connection dropped.
    @ObservationIgnored private var quietUntil = Date.distantPast

    /// The app is open and not on its way out. Checked again right before each script runs:
    /// a script that reaches an app mid-quit can launch it again.
    nonisolated private static func isLive(_ bundleID: String) -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains { !$0.isTerminated }
    }

    /// Runs AppleScript off the main thread (scripts can block while the app is busy).
    private func run(_ script: String, done: @escaping @MainActor (NSAppleEventDescriptor?) -> Void) {
        let name = source.name
        let bundleID = source.bundleID
        guard Date() >= quietUntil, Self.isLive(bundleID) else { done(nil); return }
        queue.async {
            guard Self.isLive(bundleID) else {
                DispatchQueue.main.async { MainActor.assumeIsolated { done(nil) } }
                return
            }
            var err: NSDictionary?
            let result = NSAppleScript(source: script)?.executeAndReturnError(&err)
            let code = err?[NSAppleScript.errorNumber] as? Int
            let denied = code == -1743
            // -609 connection invalid, -600 not running: the app is quitting.
            let gone = code == -609 || code == -600
            if let err { NSLog("Perch: \(name) script error \(err[NSAppleScript.errorNumber] ?? "?"): \(err[NSAppleScript.errorMessage] ?? "")") }
            nonisolated(unsafe) let out = err == nil ? result : nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.permissionDenied = denied
                    if gone { self.quietUntil = Date().addingTimeInterval(8) }
                    done(out)
                }
            }
        }
    }
}

/// The music tile's players, and which one it shows.
@MainActor @Observable
final class MediaHub {
    let players: [PlayerModel]
    /// The page the tile shows. Follows whichever app starts playing; swiping changes it too.
    var selectedID: String {
        didSet { if persist, selectedID != oldValue { UserDefaults.standard.set(selectedID, forKey: "mediaSource") } }
    }
    @ObservationIgnored private let persist: Bool

    init(players: [PlayerModel], persist: Bool = true) {
        self.players = players
        self.persist = persist
        selectedID = (persist ? UserDefaults.standard.string(forKey: "mediaSource") : nil) ?? players.first?.id ?? ""
        for p in players {
            p.onStartedPlaying = { [weak self, weak p] in
                guard let self, let p else { return }
                self.selectedID = p.id
            }
        }
    }

    /// Pages in the tile: installed apps, and always at least one.
    var visible: [PlayerModel] {
        let v = players.filter { $0.installed }
        return v.isEmpty ? Array(players.prefix(1)) : v
    }

    var selected: PlayerModel {
        visible.first { $0.id == selectedID } ?? visible[0]
    }

    func start() { players.forEach { $0.start() } }
}
