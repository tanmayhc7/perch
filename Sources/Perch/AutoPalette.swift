import AppKit
import SwiftUI

/// The Auto theme's colours, taken from the desktop picture behind the notch so the
/// open notch's glow, rings and gradients pick up the wallpaper's colours.
/// Reads the wallpaper file only: no Screen Recording permission.
@MainActor @Observable
final class AutoPalette {
    static let shared = AutoPalette()

    private(set) var accent = Color(red: 1.00, green: 0.55, blue: 0.32)
    private(set) var accent2 = Color(red: 1.00, green: 0.30, blue: 0.45)

    /// Whether the person picked a theme themselves (Auto included). Auto only reads a
    /// wallpaper kept in Desktop, Documents or Downloads when they chose it, because
    /// macOS asks for permission to read those folders.
    @ObservationIgnored var explicitlyChosen: () -> Bool = { true }
    @ObservationIgnored var isActive: () -> Bool = { false }
    @ObservationIgnored private var lastKey = ""
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var started = false
    @ObservationIgnored private let queue = DispatchQueue(label: "perch.palette", qos: .utility)

    func start() {
        guard !started else { return }
        started = true
        update()
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didWakeNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.update() } }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        // macOS doesn't announce wallpaper changes; a cheap check (path and file date) catches them.
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
    }

    func update() {
        guard isActive() else { return }
        guard let screen = NotchGeometry.detect().screen ?? NSScreen.screens.first,
              let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return useSystemAccent() }
        if Self.isProtected(url), !explicitlyChosen() { return useSystemAccent() }
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let key = "\(url.path)|\(date?.timeIntervalSince1970 ?? 0)"
        guard key != lastKey else { return }
        lastKey = key
        queue.async {
            let pair = Self.palette(from: url)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let pair else { return self.useSystemAccent() }
                    self.apply(pair.0, pair.1)
                }
            }
        }
    }

    /// The wallpaper couldn't be read (a dynamic or aerial wallpaper with no image file): use the system accent colour.
    private func useSystemAccent() {
        lastKey = "system"
        let c = NSColor.controlAccentColor.usingColorSpace(.deviceRGB) ?? .systemBlue
        let hsb = HSB(h: c.hueComponent, s: c.saturationComponent, b: c.brightnessComponent)
        apply(Self.vivid(hsb), Self.vivid(HSB(h: (hsb.h + 0.08).truncatingRemainder(dividingBy: 1), s: hsb.s, b: hsb.b), second: true))
    }

    private func apply(_ a: HSB, _ b: HSB) {
        withAnimation(.easeInOut(duration: 0.9)) { set(a, b) }
    }

    /// Sets the colours directly (snapshots render from a sample wallpaper).
    func set(_ a: HSB, _ b: HSB) {
        accent = Color(hue: a.h, saturation: a.s, brightness: a.b)
        accent2 = Color(hue: b.h, saturation: b.s, brightness: b.b)
    }

    /// Takes the colours from a picture, as `update()` does from the wallpaper. False if it has none to give.
    @discardableResult func set(from image: NSImage) -> Bool {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil), let pair = Self.palette(from: cg) else { return false }
        set(pair.0, pair.1)
        return true
    }

    // MARK: Colour extraction (pure, testable, runs off the main thread)

    struct HSB: Equatable { var h: Double; var s: Double; var b: Double }

    nonisolated static func isProtected(_ url: URL) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let protected = ["Desktop", "Documents", "Downloads", "Library/Mobile Documents"].map { "\(home)/\($0)/" }
        return protected.contains { url.path.hasPrefix($0) } || url.path.hasPrefix("/Volumes/")
    }

    nonisolated static func palette(from url: URL) -> (HSB, HSB)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                      kCGImageSourceCreateThumbnailWithTransform: true,
                                                                      kCGImageSourceThumbnailMaxPixelSize: 160] as CFDictionary)
        else { return nil }
        return palette(from: img)
    }

    /// Dominant hues of the top-centre strip (where the menu bar and notch sit), falling
    /// back to the whole picture when that strip is grey.
    nonisolated static func palette(from img: CGImage) -> (HSB, HSB)? {
        let w = img.width, h = img.height
        guard w > 0, h > 0 else { return nil }
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        // Row 0 of the buffer is the top of the picture.
        let top = histogram(px, w: w, rows: 0..<max(1, h * 35 / 100), cols: (w * 20 / 100)..<max(w * 20 / 100 + 1, w * 80 / 100))
        if let pair = pick(top) { return pair }
        let all = histogram(px, w: w, rows: 0..<h, cols: 0..<w)
        return pick(all) ?? neutral(all)
    }

    struct Histogram { var weight = [Double](repeating: 0, count: 36); var s = [Double](repeating: 0, count: 36)
                       var b = [Double](repeating: 0, count: 36); var pixels = 0; var brightness = 0.0 }

    nonisolated static func histogram(_ px: [UInt8], w: Int, rows: Range<Int>, cols: Range<Int>) -> Histogram {
        var hist = Histogram()
        for y in rows {
            for x in cols {
                let i = (y * w + x) * 4
                let r = Double(px[i]) / 255, g = Double(px[i + 1]) / 255, bl = Double(px[i + 2]) / 255
                let mx = max(r, g, bl), mn = min(r, g, bl), d = mx - mn
                hist.pixels += 1
                hist.brightness += mx
                guard mx > 0.12, d > 0.04 else { continue }
                let s = d / mx
                var hue: Double
                if mx == r { hue = (g - bl) / d } else if mx == g { hue = 2 + (bl - r) / d } else { hue = 4 + (r - g) / d }
                hue = (hue / 6).truncatingRemainder(dividingBy: 1)
                if hue < 0 { hue += 1 }
                let bin = min(35, Int(hue * 36))
                let wgt = s * mx
                hist.weight[bin] += wgt
                hist.s[bin] += s * wgt
                hist.b[bin] += mx * wgt
            }
        }
        return hist
    }

    /// Two hues at least 30° apart (or one hue and its neighbour), made bright enough to glow on black.
    nonisolated static func pick(_ hist: Histogram) -> (HSB, HSB)? {
        let total = hist.weight.reduce(0, +)
        guard hist.pixels > 0, total / Double(hist.pixels) > 0.05 else { return nil }
        // Smooth over neighbouring bins so one hue split across two bins still wins.
        let smooth = (0..<36).map { i in hist.weight[(i + 35) % 36] * 0.5 + hist.weight[i] + hist.weight[(i + 1) % 36] * 0.5 }
        guard let first = smooth.indices.max(by: { smooth[$0] < smooth[$1] }) else { return nil }
        func colour(_ i: Int) -> HSB {
            let wgt = max(hist.weight[i], 1e-9)
            return HSB(h: (Double(i) + 0.5) / 36, s: hist.s[i] / wgt, b: hist.b[i] / wgt)
        }
        func distance(_ a: Int, _ b: Int) -> Int { let d = abs(a - b); return min(d, 36 - d) }
        let second = smooth.indices
            .filter { distance($0, first) >= 3 && smooth[$0] >= smooth[first] * 0.22 }
            .max(by: { smooth[$0] < smooth[$1] })
        let a = colour(first)
        var b = second.map(colour) ?? HSB(h: (a.h + 1.0 / 12).truncatingRemainder(dividingBy: 1), s: a.s, b: a.b)
        if hist.weight[first] == 0 { return nil }
        if second == nil { b.s = a.s }
        return (vivid(a), vivid(b, second: true))
    }

    /// A grey wallpaper: silvery accents, like Graphite, warmed or cooled a touch toward its overall tone.
    nonisolated static func neutral(_ hist: Histogram) -> (HSB, HSB) {
        let avg = hist.pixels > 0 ? hist.brightness / Double(hist.pixels) : 0.5
        return (HSB(h: 0.6, s: 0.04, b: 0.92), HSB(h: 0.6, s: 0.06, b: max(0.5, min(0.7, avg + 0.2))))
    }

    nonisolated static func vivid(_ c: HSB, second: Bool = false) -> HSB {
        HSB(h: c.h, s: min(max(c.s * 1.15, second ? 0.5 : 0.45), 0.85), b: second ? 0.95 : min(max(c.b, 0.9), 1))
    }
}
