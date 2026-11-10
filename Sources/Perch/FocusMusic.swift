import AppKit
import AVFoundation
import UniformTypeIdentifiers

/// Plays music the person picked while the focus timer runs: an audio file (mp3, m4a, wav, …)
/// on loop, or a YouTube video played in a hidden web view (see `YouTubeAudio`).
/// Fades in when a session starts or resumes, fades out when it pauses, finishes or is stopped.
/// Break sessions stay quiet.
@MainActor @Observable
final class FocusMusic {
    enum Source: Equatable {
        case file(URL)
        case youtube(id: String, title: String)
    }

    /// What plays, or nil when focus music is off.
    private(set) var source: Source?
    /// Playing right now (not muted, not paused).
    private(set) var playing = false
    /// Silenced for the rest of this session from the notch; the next session plays again.
    private(set) var muted = false
    /// A focus session is under way with music (playing, paused or muted).
    private(set) var inSession = false
    /// The timer is counting down (not paused).
    private(set) var timerRunning = false
    /// Album art from the file, or the video's thumbnail.
    private(set) var artwork: NSImage?

    var title: String? {
        switch source {
        case .file(let url): url.deletingPathExtension().lastPathComponent
        case .youtube(_, let title): title
        case nil: nil
        }
    }
    var isYouTube: Bool { if case .youtube = source { true } else { false } }
    /// Where YouTube plays: Brave (ad-free) when it's installed, else Perch's own web view.
    var youTubeEngine: String { youtube?.engine ?? (BravePage.executable() != nil ? "Brave" : "Perch") }

    @ObservationIgnored var onAlert: ((Toast) -> Void)?
    /// Called when focus music starts: pauses Spotify or Music instead of playing on top, and turns the tile to this page.
    @ObservationIgnored var onWillPlay: (() -> Void)?
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var youtube: YouTubeAudio?
    @ObservationIgnored private var fadeWork: DispatchWorkItem?
    @ObservationIgnored private let defaults: UserDefaults

    /// The music tile's page for focus music.
    nonisolated static let pageID = "focus"
    static let volume: Float = 0.8
    static let fade: TimeInterval = 2

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        source = loadSource()
        loadArtwork()
    }

    // MARK: Choosing

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose focus music"
        panel.prompt = "Use for Focus"
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard (try? AVAudioPlayer(contentsOf: url)) != nil else {
            onAlert?(Toast(symbol: "music.note", tint: .warning, title: "Can't play that file", subtitle: url.lastPathComponent))
            return
        }
        set(.file(url))
    }

    /// Asks for a YouTube link, filled in from the clipboard when it holds one.
    func chooseYouTube() {
        let alert = NSAlert()
        alert.messageText = "Play a YouTube video during focus"
        alert.informativeText = "Paste a link to a video or a live stream. Perch plays its sound in the background while the timer runs; ads may play too."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "https://www.youtube.com/watch?v=…"
        if let clip = NSPasteboard.general.string(forType: .string), YouTubeAudio.videoID(from: clip) != nil { field.stringValue = clip }
        else if case .youtube(let id, _) = source { field.stringValue = "https://youtu.be/\(id)" }
        alert.accessoryView = field
        alert.addButton(withTitle: "Use for Focus")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let id = YouTubeAudio.videoID(from: field.stringValue) else {
            onAlert?(Toast(symbol: "play.rectangle", tint: .warning, title: "That isn't a YouTube video link",
                           subtitle: "Copy the link from the video's Share button"))
            return
        }
        set(.youtube(id: id, title: "YouTube video"))
        // The real title, from YouTube's public oEmbed endpoint. A video that doesn't exist answers 404.
        Task {
            guard let t = await YouTubeAudio.title(id: id) else { return }
            if case .youtube(id, _) = source { set(.youtube(id: id, title: t), restart: false) }
        }
    }

    func remove() { set(nil) }

    private func set(_ new: Source?, restart: Bool = true) {
        switch new {
        case .file(let url):
            // A bookmark follows the file if it's renamed or moved (Perch isn't sandboxed, so no security scope).
            defaults.set("file", forKey: "focusMusicKind")
            if let data = try? url.bookmarkData() { defaults.set(data, forKey: "focusMusicBookmark") }
        case .youtube(let id, let title):
            defaults.set("youtube", forKey: "focusMusicKind")
            defaults.set(id, forKey: "focusMusicYouTubeID")
            defaults.set(title, forKey: "focusMusicYouTubeTitle")
        case nil:
            for k in ["focusMusicKind", "focusMusicBookmark", "focusMusicYouTubeID", "focusMusicYouTubeTitle"] { defaults.removeObject(forKey: k) }
        }
        let changed = new != source
        source = new
        guard restart, changed else { return }
        loadArtwork()
        let wasPlaying = playing
        teardown()
        if new == nil { inSession = false; muted = false }
        else if wasPlaying { play() }
    }

    private func loadSource() -> Source? {
        switch defaults.string(forKey: "focusMusicKind") ?? (defaults.data(forKey: "focusMusicBookmark") != nil ? "file" : nil) {
        case "file": resolveFile().map { .file($0) }
        case "youtube": defaults.string(forKey: "focusMusicYouTubeID").map {
            .youtube(id: $0, title: defaults.string(forKey: "focusMusicYouTubeTitle") ?? "YouTube video")
        }
        default: nil
        }
    }

    private func resolveFile() -> URL? {
        guard let data = defaults.data(forKey: "focusMusicBookmark") else { return nil }
        var stale = false
        return try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale)
    }

    private func loadArtwork() {
        artwork = nil
        let wanted = source
        Task {
            let image: NSImage?
            switch wanted {
            case .file(let url):
                let items = (try? await AVURLAsset(url: url).load(.commonMetadata)) ?? []
                let art = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .commonIdentifierArtwork).first
                image = (try? await art?.load(.dataValue)).flatMap { NSImage(data: $0) }
            case .youtube(let id, _):
                image = await YouTubeAudio.thumbnail(id: id)
            case nil:
                image = nil
            }
            if source == wanted { artwork = image }
        }
    }

    // MARK: Timer

    /// A session started or resumed.
    func begin(label: String) {
        guard label != "Break", source != nil else { return }
        timerRunning = true
        if !inSession { inSession = true; muted = false }
        guard !muted else { return }
        play()
    }

    /// The session paused.
    func pause() {
        timerRunning = false
        fadeOutAndPause()
    }

    /// The session finished or was stopped.
    func end() {
        timerRunning = false
        inSession = false
        muted = false
        stopPlayback()
    }

    /// Play/pause from the notch: silence (or bring back) the music for this session.
    func toggleMute() {
        guard inSession else { return }
        muted.toggle()
        if muted { fadeOutAndPause() } else if timerRunning { play() }
    }

    /// Stop from the notch: no more music this session, and let go of the player (and YouTube's page).
    func stopForSession() {
        guard inSession else { return }
        muted = true
        stopPlayback()
    }

    func stopBeforeQuit() { player?.stop(); youtube?.close() }

    /// Snapshots only: show a source mid-session without playing anything.
    func preview(_ source: Source, artwork: NSImage?) {
        self.source = source
        self.artwork = artwork
        inSession = true
        timerRunning = true
        playing = true
    }

    /// Development only: what the hidden YouTube page's video is doing.
    func debugState(_ done: @escaping (String) -> Void) {
        guard let youtube else { return done("no youtube page") }
        youtube.debugState(done)
    }

    // MARK: Playback

    private func play() {
        switch source {
        case .file: playFile()
        case .youtube(let id, _): playYouTube(id: id)
        case nil: return
        }
    }

    private func playFile() {
        // The file may have been deleted or its drive unplugged since it was picked.
        guard let file = resolveFile(), FileManager.default.fileExists(atPath: file.path) else {
            onAlert?(Toast(symbol: "music.note", tint: .warning, title: "Focus music is missing",
                           subtitle: "Choose it again from the ••• menu"))
            inSession = false
            return
        }
        if player == nil || player?.url != file {
            player?.stop()
            guard let p = try? AVAudioPlayer(contentsOf: file) else {
                onAlert?(Toast(symbol: "music.note", tint: .warning, title: "Can't play focus music", subtitle: file.lastPathComponent))
                return
            }
            p.numberOfLoops = -1
            p.prepareToPlay()
            player = p
        }
        guard let player else { return }
        onWillPlay?()
        fadeWork?.cancel()
        if !player.isPlaying { player.volume = 0; player.play() }
        player.setVolume(Self.volume, fadeDuration: Self.fade)
        playing = true
    }

    private func playYouTube(id: String) {
        if youtube?.id != id {
            youtube?.close()
            let yt = YouTubeAudio(id: id, volume: Double(Self.volume), fade: Self.fade)
            yt.onFailure = { [weak self, weak yt] in
                guard let self, let yt, self.youtube === yt else { return }
                self.onAlert?(Toast(symbol: "play.rectangle", tint: .warning, title: "Couldn't play the YouTube video",
                                    subtitle: "Check your connection, or pick another video"))
                self.teardown()
                // Leave it stopped for this session; the play button tries again.
                if self.inSession { self.muted = true }
            }
            youtube = yt
        }
        onWillPlay?()
        youtube?.play()
        playing = true
    }

    private func fadeOutAndPause() {
        guard playing else { return }
        playing = false
        if let youtube { youtube.pause(); return }
        guard let player else { return }
        fadeWork?.cancel()
        player.setVolume(0, fadeDuration: Self.fade)
        let work = DispatchWorkItem { [weak self, weak player] in
            guard let player, self?.playing == false else { return }
            player.pause()
        }
        fadeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.fade, execute: work)
    }

    /// Fade out, then let go of the player.
    private func stopPlayback() {
        guard playing else { teardown(); return }
        playing = false
        fadeWork?.cancel()
        player?.setVolume(0, fadeDuration: Self.fade)
        youtube?.pause()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.playing else { return }
            self.teardown()
        }
        fadeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.fade, execute: work)
    }

    private func teardown() {
        fadeWork?.cancel()
        player?.stop()
        player = nil
        youtube?.close()
        youtube = nil
        playing = false
    }
}
