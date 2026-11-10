import AppKit
import WebKit

/// Plays a YouTube video's sound in a page nobody sees, for focus music.
///
/// The page is the ordinary watch page (so videos that can't be embedded still play), opened in
/// a private, headless Brave when Brave is installed (its Shields block YouTube's ads), or else in
/// a web view in an invisible, off-screen window. Either way Perch drives the page's <video>
/// element itself, once a second and many times a second while fading: playing, pausing, fading
/// the volume, looping at the end, pressing Skip on ads, and coming back to the video if YouTube
/// moves on to another one.
///
/// Perch has to start playback itself: a hidden page doesn't autoplay, and WebKit only lets a
/// script start sound when Perch runs it (it counts as the person's own action). A hidden page's
/// timers also slow to about once a second, too coarse for a fade, so the fade runs here too.
@MainActor
final class YouTubeAudio {
    let id: String
    /// Nothing played within `startTimeout` of asking, or the page couldn't load.
    var onFailure: (() -> Void)?
    /// Which page is playing: "Brave", or "Perch" for the built-in web view.
    private(set) var engine: String

    private let volume: Double
    private let fade: TimeInterval
    private var page: HiddenPage?
    private var wantPlaying = false
    /// The volume Perch has set on the page; it moves toward `volume` or 0 while fading.
    private var current = 0.0
    private var fader: Timer?
    private var ticker: Timer?
    /// When playback was last asked for and hasn't started yet.
    private var waitingSince: Date?
    private var lastTime = -1.0
    /// Where the video was when the page closed during a long pause; it reopens there.
    private var resumeAt: Double = 0
    private var idleClose: DispatchWorkItem?
    static let startTimeout: TimeInterval = 25
    /// A page paused this long closes (and with it the hidden Brave); playing again reopens it.
    static let idleTimeout: TimeInterval = 120

    init(id: String, volume: Double, fade: TimeInterval) {
        self.id = id
        self.volume = volume
        self.fade = fade
        engine = BravePage.executable() != nil ? "Brave" : "Perch"
    }

    func play() {
        wantPlaying = true
        idleClose?.cancel()
        idleClose = nil
        if page == nil { open() }
        if waitingSince == nil { waitingSince = Date() }
        startFade()
    }

    /// Fades out, then pauses (in the page).
    func pause() {
        wantPlaying = false
        waitingSince = nil
        startFade()
        idleClose?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.wantPlaying, self.page != nil else { return }
            self.resumeAt = max(0, self.lastTime)
            self.close()
        }
        idleClose = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.idleTimeout, execute: work)
    }

    func close() {
        idleClose?.cancel()
        idleClose = nil
        fader?.invalidate()
        fader = nil
        ticker?.invalidate()
        ticker = nil
        page?.close()
        page = nil
    }

    /// Development only.
    func debugState(_ done: @escaping (String) -> Void) {
        guard let page else { return done("closed") }
        page.run("""
        (() => { const v = document.querySelector('#movie_player video') || document.querySelector('video');
          return v ? `t=${v.currentTime.toFixed(1)} paused=${v.paused} vol=${v.volume.toFixed(2)} ad=${!!document.querySelector('.ad-showing')} title=${document.title.slice(0, 40)}` : 'no video ' + document.title })()
        """) { done("\(self.engine): \($0 ?? "?")") }
    }

    // MARK: Page

    private func open() {
        var url = Self.watchURL(id)
        // Reopening after a long pause: carry on where it was (a live stream ignores this).
        if resumeAt >= 1, let u = URL(string: url.absoluteString + "&t=\(Int(resumeAt))s") { url = u }
        resumeAt = 0
        let fail: () -> Void = { [weak self] in self?.pageFailed() }
        if engine == "Brave", let brave = BravePage(onFallback: { [weak self] in self?.fallBackToWebKit() }) {
            page = brave
            brave.open(url, onFail: fail)
        } else {
            engine = "Perch"
            let web = WebKitPage()
            page = web
            web.open(url, onFail: fail)
        }
        lastTime = -1
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// Brave wouldn't start: play in the built-in web view instead.
    private func fallBackToWebKit() {
        NSLog("Perch: Brave didn't start; playing YouTube focus music in the built-in web view")
        close()
        engine = "Perch"
        if wantPlaying { play() }
    }

    private func pageFailed() {
        waitingSince = nil
        onFailure?()
    }

    /// Once a second: keep the page where Perch wants it, and notice whether sound is coming out.
    private func tick() {
        page?.run(Self.keep(id: id, playing: wantPlaying, volume: current)) { [weak self] result in
            guard let self, let result, let data = result.data(using: .utf8),
                  let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let t = state["t"] as? Double, let paused = state["paused"] as? Bool else { return }
            // Sound is coming out (an ad counts: the video follows it).
            if !paused, self.lastTime >= 0, t > self.lastTime { self.waitingSince = nil }
            self.lastTime = t
        }
        if let since = waitingSince, Date().timeIntervalSince(since) > Self.startTimeout {
            waitingSince = nil
            onFailure?()
        }
    }

    private func startFade() {
        tick()
        guard fader == nil else { return }
        var last = Date()
        fader = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { t.invalidate(); return }
                let now = Date()
                let target = self.wantPlaying ? self.volume : 0
                let step = self.volume * now.timeIntervalSince(last) / max(0.1, self.fade)
                last = now
                self.current = self.current < target ? min(target, self.current + step) : max(target, self.current - step)
                self.page?.run(Self.setVolume(self.current, playing: self.wantPlaying), done: nil)
                if self.current == target { t.invalidate(); self.fader = nil }
            }
        }
    }

    private static let findVideo = "(document.querySelector('#movie_player video') || document.querySelector('video'))"

    private static func setVolume(_ vol: Double, playing: Bool) -> String {
        """
        (() => { window.__perchVol = \(vol); const v = \(findVideo); if (!v) return;
          v.volume = \(vol); if (!\(playing) && \(vol) <= 0.001 && !v.paused) v.pause(); })()
        """
    }

    /// The once-a-second script. Returns the video's state as JSON.
    private static func keep(id: String, playing: Bool, volume: Double) -> String {
        """
        (() => {
          const id = \(jsString(id)), want = \(playing), vol = \(volume);
          window.__perchBeat = Date.now(); window.__perchVol = vol;
          // Between Perch's visits: hold the volume (YouTube resets it around ads), and pause if
          // Perch stops visiting (it quit or crashed) so nothing plays on with nobody to stop it.
          if (!window.__perchGuard) window.__perchGuard = setInterval(() => {
            const v = \(findVideo); if (!v) return;
            if (Date.now() - window.__perchBeat > 10000) { if (!v.paused) v.pause(); return; }
            if (Math.abs(v.volume - window.__perchVol) > 0.01) v.volume = window.__perchVol;
          }, 500);
          // YouTube moved on to another video (autoplay, an end screen): come back.
          if (location.pathname === '/watch' && new URLSearchParams(location.search).get('v') !== id) {
            location.replace('https://www.youtube.com/watch?v=' + id); return 'moved';
          }
          const v = \(findVideo); if (!v) return 'none';
          const ad = !!document.querySelector('.ad-showing');
          v.volume = vol; if (v.muted) v.muted = false;
          if (want && (v.paused || v.ended)) {
            const p = document.getElementById('movie_player');
            if (v.ended && p && p.seekTo) p.seekTo(0, true);
            if (p && p.playVideo) p.playVideo();
            v.play().catch(() => {});
          } else if (!want && vol <= 0.001 && !v.paused) v.pause();
          // Loop before YouTube's end screen takes over.
          if (want && !ad && isFinite(v.duration) && v.duration > 5 && v.duration - v.currentTime < 1.5) v.currentTime = 0;
          const skip = document.querySelector('.ytp-skip-ad-button, .ytp-ad-skip-button, .ytp-ad-skip-button-modern');
          if (skip && skip.offsetParent !== null) skip.click();
          return JSON.stringify({ t: v.currentTime, paused: v.paused, ad });
        })()
        """
    }

    private static func jsString(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s])) ?? Data("[\"\"]".utf8)
        return String(decoding: data, as: UTF8.self).dropFirst().dropLast().description
    }

    // MARK: Links

    static func watchURL(_ id: String) -> URL { URL(string: "https://www.youtube.com/watch?v=\(id)")! }

    /// The video ID in a YouTube link: watch?v=, youtu.be/, /shorts/, /live/, /embed/, music.youtube.com.
    static func videoID(from text: String) -> String? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.contains("://") { t = "https://" + t }
        guard let c = URLComponents(string: t), let host = c.host?.lowercased() else { return nil }
        let path = c.path.split(separator: "/").map(String.init)
        var id: String?
        if host == "youtu.be" || host.hasSuffix(".youtu.be") {
            id = path.first
        } else if host == "youtube.com" || host.hasSuffix(".youtube.com") || host.hasSuffix("youtube-nocookie.com") {
            if let v = c.queryItems?.first(where: { $0.name == "v" })?.value { id = v }
            else if path.count >= 2, ["shorts", "live", "embed", "v"].contains(path[0]) { id = path[1] }
        }
        guard let id, id.count == 11, id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
        return id
    }

    /// The video's title, from YouTube's oEmbed endpoint.
    static func title(id: String) async -> String? {
        var c = URLComponents(string: "https://www.youtube.com/oembed")!
        c.queryItems = [.init(name: "url", value: watchURL(id).absoluteString), .init(name: "format", value: "json")]
        guard let (data, resp) = try? await URLSession.shared.data(from: c.url!),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["title"] as? String
    }

    static func thumbnail(id: String) async -> NSImage? {
        guard let (data, _) = try? await URLSession.shared.data(from: URL(string: "https://i.ytimg.com/vi/\(id)/mqdefault.jpg")!) else { return nil }
        return NSImage(data: data)
    }
}

// MARK: - Pages

/// Somewhere a hidden YouTube page runs.
@MainActor
protocol HiddenPage: AnyObject {
    func open(_ url: URL, onFail: @escaping () -> Void)
    /// Runs a script as if the person did it (so it may start sound); `done` gets its string result.
    func run(_ js: String, done: ((String?) -> Void)?)
    func close()
}

/// A web view in an invisible, off-screen window.
@MainActor
final class WebKitPage: NSObject, HiddenPage, WKNavigationDelegate {
    private var window: NSWindow?
    private var web: WKWebView?
    private var onFail: (() -> Void)?

    func open(_ url: URL, onFail: @escaping () -> Void) {
        self.onFail = onFail
        let cfg = WKWebViewConfiguration()
        cfg.mediaTypesRequiringUserActionForPlayback = []
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 360), configuration: cfg)
        // Safari's own user agent, so YouTube serves the page it serves Safari.
        web.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        web.navigationDelegate = self
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 640, height: 360),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.transient, .ignoresCycle]
        window.contentView = web
        window.orderFrontRegardless()
        self.web = web
        self.window = window
        web.load(URLRequest(url: url))
    }

    func run(_ js: String, done: ((String?) -> Void)?) {
        guard let web else { done?(nil); return }
        web.evaluateJavaScript(js) { r, _ in done?(r as? String) }
    }

    func close() {
        web?.stopLoading()
        web?.loadHTMLString("", baseURL: nil)
        window?.orderOut(nil)
        window?.contentView = nil
        web = nil
        window = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }

    private func failed(_ error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        NSLog("Perch: YouTube focus music: \(error.localizedDescription)")
        onFail?()
    }
}

/// A private, headless Brave (its own profile, no window, no Dock icon) driven over the
/// DevTools protocol on a local port. Brave's Shields block YouTube's ads.
@MainActor
final class BravePage: HiddenPage {
    private var process: Process?
    private var socket: URLSessionWebSocketTask?
    private var nextID = 0
    private var replies: [Int: (String?) -> Void] = [:]
    private var onFail: (() -> Void)?
    private let onFallback: () -> Void
    private var closed = false
    /// Brave pages open right now; the after-close sweep mustn't end a newer one.
    private static var openCount = 0

    static let bundleID = "com.brave.Browser"

    static func executable() -> URL? {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let exe = app.appendingPathComponent("Contents/MacOS/Brave Browser")
        return FileManager.default.isExecutableFile(atPath: exe.path) ? exe : nil
    }

    /// Perch's own Brave profile, apart from the person's: no history, logins or extensions of theirs.
    nonisolated static var profile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Perch/Brave", isDirectory: true)
    }

    /// Ends any Brave still running on Perch's profile (left by a crash, or helpers slow to exit).
    nonisolated static func sweep() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        p.arguments = ["-f", "--user-data-dir=\(profile.path)"]
        try? p.run()
    }

    /// `onFallback`: Brave didn't start; play somewhere else.
    init?(onFallback: @escaping () -> Void) {
        guard Self.executable() != nil else { return nil }
        self.onFallback = onFallback
    }

    func open(_ url: URL, onFail: @escaping () -> Void) {
        self.onFail = onFail
        guard let exe = Self.executable() else { onFallback(); return }
        let profile = Self.profile
        try? FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let portFile = profile.appendingPathComponent("DevToolsActivePort")
        try? FileManager.default.removeItem(at: portFile)
        // Brave runs under a small shell that watches Perch: if Perch goes away without closing it
        // (a crash, a force quit), the shell ends Brave and its helpers within a couple of seconds.
        // Closing normally sends the shell TERM, which ends Brave the same way.
        let watcher = """
        "$0" "$@" & b=$!
        trap 'kill $b 2>/dev/null; exit 0' TERM
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null && kill -0 $b 2>/dev/null; do sleep 2 & wait $!; done
        kill $b 2>/dev/null; sleep 2; /usr/bin/pkill -f -- "--user-data-dir=\(profile.path)"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", watcher, exe.path,
            "--headless=new", "--user-data-dir=\(profile.path)",
            // Port 0: Brave picks a free port and writes it to DevToolsActivePort. Local connections only.
            "--remote-debugging-port=0", "--remote-debugging-address=127.0.0.1",
            "--no-first-run", "--no-default-browser-check", "--window-size=1280,720",
            "--autoplay-policy=no-user-gesture-required",
            url.absoluteString,
        ]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { onFallback(); return }
        process = p
        Self.openCount += 1
        Task { await connect(portFile: portFile) }
    }

    private func connect(portFile: URL) async {
        // Brave writes its port within a second or two of starting.
        var port: String?
        for _ in 0..<60 where !closed {
            if let text = try? String(contentsOf: portFile, encoding: .utf8), let first = text.split(separator: "\n").first {
                port = String(first); break
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard !closed else { return }
        guard let port, let list = URL(string: "http://127.0.0.1:\(port)/json/list") else { close(); onFallback(); return }
        var wsURL: URL?
        for _ in 0..<20 where !closed {
            if let (data, _) = try? await URLSession.shared.data(from: list),
               let targets = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
               let page = targets.first(where: { $0["type"] as? String == "page" }),
               let ws = (page["webSocketDebuggerUrl"] as? String).flatMap(URL.init(string:)) {
                wsURL = ws; break
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard !closed else { return }
        guard let wsURL else { close(); onFallback(); return }
        let socket = URLSession.shared.webSocketTask(with: wsURL)
        self.socket = socket
        socket.resume()
        receive()
    }

    private func receive() {
        socket?.receive { [weak self] result in
            Task { @MainActor in
                guard let self, !self.closed else { return }
                switch result {
                case .failure:
                    // Brave went away mid-session.
                    self.close()
                    self.onFail?()
                case .success(let message):
                    if case .string(let text) = message, let data = text.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let id = json["id"] as? Int, let reply = self.replies.removeValue(forKey: id) {
                        let value = ((json["result"] as? [String: Any])?["result"] as? [String: Any])?["value"]
                        reply(value as? String)
                    }
                    self.receive()
                }
            }
        }
    }

    func run(_ js: String, done: ((String?) -> Void)?) {
        guard let socket else { done?(nil); return }
        nextID += 1
        if let done { replies[nextID] = done }
        let msg: [String: Any] = ["id": nextID, "method": "Runtime.evaluate",
                                  "params": ["expression": js, "userGesture": true, "returnByValue": true]]
        guard let data = try? JSONSerialization.data(withJSONObject: msg) else { return }
        socket.send(.string(String(decoding: data, as: UTF8.self))) { _ in }
    }

    func close() {
        guard !closed else { return }
        closed = true
        if process != nil { Self.openCount -= 1 }
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        replies.values.forEach { $0(nil) }
        replies = [:]
        process?.terminate()
        process = nil
        // Brave's helper processes can outlive its main one.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            MainActor.assumeIsolated { if Self.openCount == 0 { Self.sweep() } }
        }
    }
}
