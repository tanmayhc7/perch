import AppKit
import WebKit

/// Plays a YouTube video's sound in a web view nobody sees, for focus music.
///
/// It loads the ordinary watch page (so videos that can't be embedded still play) in an
/// invisible, off-screen window, and drives the page's <video> element from a small script:
/// playing, pausing, fading the volume, looping at the end, pressing Skip on ads when YouTube
/// offers it, and coming back to the video if YouTube moves on to another one.
/// Starting playback from the script matters: a hidden page doesn't autoplay on its own.
@MainActor
final class YouTubeAudio: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    let id: String
    /// Nothing played within `startTimeout` of asking, or the page failed to load.
    var onFailure: (() -> Void)?

    private let volume: Double
    private let fade: TimeInterval
    private var window: NSWindow?
    private var web: WKWebView?
    private var wantPlaying = false
    /// The volume Perch has set on the page; it moves toward `volume` or 0 while fading.
    private var current = 0.0
    private var fader: Timer?
    /// When playback was last asked for and hasn't started yet.
    private var waitingSince: Date?
    private var watchdog: Timer?
    static let startTimeout: TimeInterval = 25

    init(id: String, volume: Double, fade: TimeInterval) {
        self.id = id
        self.volume = volume
        self.fade = fade
        super.init()
    }

    func play() {
        wantPlaying = true
        if web == nil { load() }
        if waitingSince == nil { waitingSince = Date() }
        startFade()
    }

    /// Fades out, then pauses (in the page).
    func pause() {
        wantPlaying = false
        waitingSince = nil
        startFade()
    }

    private func startFade() {
        push()
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
                self.push()
                if self.current == target { t.invalidate(); self.fader = nil }
            }
        }
    }

    func close() {
        fader?.invalidate()
        fader = nil
        watchdog?.invalidate()
        watchdog = nil
        web?.configuration.userContentController.removeScriptMessageHandler(forName: "perch")
        web?.stopLoading()
        web?.loadHTMLString("", baseURL: nil)
        window?.orderOut(nil)
        window?.contentView = nil
        web = nil
        window = nil
    }

    /// Development only.
    func debugState(_ done: @escaping (String) -> Void) {
        guard let web else { return done("closed") }
        web.evaluateJavaScript("""
        (() => { const v = document.querySelector('#movie_player video') || document.querySelector('video');
          return v ? `t=${v.currentTime.toFixed(1)} paused=${v.paused} vol=${v.volume.toFixed(2)} ad=${!!document.querySelector('.ad-showing')} ready=${v.readyState} err=${v.error && v.error.code} title=${document.title.slice(0, 40)} state=${document.getElementById('movie_player')?.getPlayerState?.()}` : 'no video ' + document.title })()
        """) { r, e in done((r as? String) ?? e.map { "\($0)" } ?? "?") }
    }

    // MARK: Page

    private func load() {
        let cfg = WKWebViewConfiguration()
        cfg.mediaTypesRequiringUserActionForPlayback = []
        let ucc = WKUserContentController()
        ucc.add(WeakHandler(self), name: "perch")
        ucc.addUserScript(WKUserScript(source: Self.script(id: id, fade: fade), injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        cfg.userContentController = ucc
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
        web.load(URLRequest(url: Self.watchURL(id)))
        watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.wantPlaying { self.push() }
                guard let since = self.waitingSince, Date().timeIntervalSince(since) > Self.startTimeout else { return }
                self.waitingSince = nil
                self.onFailure?()
            }
        }
    }

    /// Tells the page what Perch wants. The script keeps pushing the video toward it.
    private func push() {
        web?.evaluateJavaScript("window.__perch && window.__perch.want(\(wantPlaying), \(current))", completionHandler: nil)
    }

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        if body["ready"] as? Bool == true { push() }
        // Sound is coming out (an ad counts: the video follows it).
        if body["playing"] as? Bool == true { waitingSince = nil }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }

    private func failed(_ error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        NSLog("Perch: YouTube focus music: \(error.localizedDescription)")
        waitingSince = nil
        onFailure?()
    }

    private static func script(id: String, fade: TimeInterval) -> String {
        """
        (() => {
          const id = \(jsString(id));
          const s = { playing: false, vol: 0 };
          // Perch drives this: starting playback only works from Perch's side (WebKit counts that as the
          // person's own action; a hidden page's timer it doesn't), and a hidden page's timers are slowed
          // to about once a second, too coarse for a fade. So Perch sets the volume itself, many times a
          // second while fading and once a second otherwise.
          window.__perch = { want(p, vol) {
            s.playing = p; s.vol = vol;
            const vid = document.querySelector('#movie_player video') || document.querySelector('video');
            if (!vid) return;
            vid.volume = vol;
            if (vid.muted) vid.muted = false;
            if (!p && vol <= 0.001 && !vid.paused) vid.pause();
            if (!p || !(vid.paused || vid.ended)) return;
            const player = document.getElementById('movie_player');
            if (vid.ended && player && player.seekTo) player.seekTo(0, true);
            if (player && player.playVideo) player.playVideo();
            vid.play().catch(() => {});
          } };
          const post = m => { try { webkit.messageHandlers.perch.postMessage(m) } catch (e) {} };
          let lastT = -1;
          setInterval(() => {
            // YouTube moved on to another video (autoplay, an end screen): come back.
            if (location.pathname === '/watch' && new URLSearchParams(location.search).get('v') !== id) {
              location.replace('https://www.youtube.com/watch?v=' + id); return;
            }
            const v = document.querySelector('#movie_player video') || document.querySelector('video');
            if (!v) return;
            // YouTube resets the volume around ads.
            if (Math.abs(v.volume - s.vol) > 0.01) v.volume = s.vol;
            if (v.muted) v.muted = false;
            if (!s.playing && s.vol <= 0.001 && !v.paused) v.pause();
            // Loop before YouTube's end screen takes over.
            if (s.playing && isFinite(v.duration) && v.duration > 5 && v.duration - v.currentTime < 0.6
                && !document.querySelector('.ad-showing')) v.currentTime = 0;
            const skip = document.querySelector('.ytp-skip-ad-button, .ytp-ad-skip-button, .ytp-ad-skip-button-modern');
            if (skip && skip.offsetParent !== null) skip.click();
            const moving = !v.paused && lastT >= 0 && v.currentTime > lastT;
            lastT = v.currentTime;
            if (moving) post({ playing: true });
          }, 250);
          post({ ready: true });
        })();
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

/// WKUserContentController keeps its handlers alive; this keeps it from keeping the player alive.
private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: (WKScriptMessageHandler & NSObject)?
    init(_ target: WKScriptMessageHandler & NSObject) { self.target = target }
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(ucc, didReceive: message)
    }
}
