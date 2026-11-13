import AppKit
import CryptoKit

/// "Check for updates" in the menu: one click finds the latest release on GitHub, downloads it,
/// checks it against GitHub's checksum, swaps this app for it and reopens Perch.
/// Nothing is contacted until the person clicks.
@MainActor @Observable
final class Updater {
    enum Phase: Equatable { case idle, checking, downloading(String), installing(String) }

    static let repo = "tanmayhc7/perch"
    private(set) var phase: Phase = .idle
    @ObservationIgnored var onAlert: ((Toast) -> Void)?

    /// This copy's version ("0.3.3"), or nil when run outside an app bundle (a development build).
    var current: String? { appURL == nil ? nil : Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String }
    private var appURL: URL? { Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main.bundleURL : nil }

    var menuTitle: String {
        switch phase {
        case .idle: "Check for updates"
        case .checking: "Checking for updates…"
        case .downloading(let v): "Downloading Perch \(v)…"
        case .installing(let v): "Installing Perch \(v)…"
        }
    }
    var busy: Bool { phase != .idle }

    private struct Release: Decodable {
        struct Asset: Decodable {
            var name: String
            var browser_download_url: URL
            var digest: String?
        }
        var tag_name: String
        var assets: [Asset]
    }

    private struct Problem: Error { var title: String; var detail: String }

    func run() {
        guard phase == .idle else { return }
        phase = .checking
        Task {
            do {
                try await update()
            } catch let p as Problem {
                phase = .idle
                onAlert?(Toast(symbol: "exclamationmark.triangle.fill", tint: .warning, title: p.title, subtitle: p.detail,
                               actionTitle: "Releases", action: { NSWorkspace.shared.open(URL(string: "https://github.com/\(Self.repo)/releases/latest")!) },
                               seconds: 9))
            } catch {
                phase = .idle
                onAlert?(Toast(symbol: "wifi.slash", tint: .warning, title: "Couldn't check for updates", subtitle: "Check your connection and try again"))
            }
        }
    }

    private func update() async throws {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let release = try? JSONDecoder().decode(Release.self, from: data) else {
            throw Problem(title: "Couldn't check for updates", detail: "GitHub didn't answer; try again in a minute")
        }
        let latest = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
        guard let appURL, let current else {
            throw Problem(title: "Perch \(latest) is the latest", detail: "This is a development build; it doesn't update itself")
        }
        guard Self.isNewer(latest, than: current) else {
            phase = .idle
            onAlert?(Toast(symbol: "checkmark.circle.fill", tint: .calm, title: "Perch is up to date", subtitle: "Version \(current)"))
            return
        }
        guard FileManager.default.isWritableFile(atPath: appURL.deletingLastPathComponent().path) else {
            throw Problem(title: "Perch \(latest) is out", detail: "Perch can't replace itself in this folder; download it instead")
        }
        guard let asset = release.assets.first(where: { $0.name == "perch-\(latest).zip" }),
              asset.browser_download_url.scheme == "https", asset.browser_download_url.host() == "github.com",
              let digest = asset.digest, digest.hasPrefix("sha256:") else {
            throw Problem(title: "Perch \(latest) is out", detail: "Its download couldn't be checked; get it from GitHub")
        }

        phase = .downloading(latest)
        onAlert?(Toast(symbol: "arrow.down.circle.fill", title: "Updating to Perch \(latest)", subtitle: "Perch will reopen in a moment", seconds: 20))
        let (downloaded, _) = try await URLSession.shared.download(from: asset.browser_download_url)
        let expected = String(digest.dropFirst("sha256:".count)).lowercased()
        let bundleID = Bundle.main.bundleIdentifier ?? ""

        phase = .installing(latest)
        // Hashing and unzipping happen off the main thread.
        let staged: URL = try await Task.detached {
            let fm = FileManager.default
            let work = fm.temporaryDirectory.appendingPathComponent("perch-update-\(UUID().uuidString)")
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            let zip = work.appendingPathComponent("perch.zip")
            try fm.moveItem(at: downloaded, to: zip)
            let actual = SHA256.hash(data: try Data(contentsOf: zip)).map { String(format: "%02x", $0) }.joined()
            guard actual == expected else {
                try? fm.removeItem(at: work)
                throw Problem(title: "The update wasn't installed", detail: "The download didn't match GitHub's checksum")
            }
            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            unzip.arguments = ["-x", "-k", zip.path, work.appendingPathComponent("unzipped").path]
            try unzip.run()
            unzip.waitUntilExit()
            let app = work.appendingPathComponent("unzipped/Perch.app")
            // It has to be Perch: the same bundle identifier as the copy that's running.
            guard unzip.terminationStatus == 0, let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
                  info["CFBundleIdentifier"] as? String == bundleID, !bundleID.isEmpty else {
                try? fm.removeItem(at: work)
                throw Problem(title: "The update wasn't installed", detail: "The download isn't a Perch app")
            }
            return app
        }.value

        // A small shell waits for this copy to quit, swaps the app (putting the old one back if the copy
        // fails) and opens the new one. Paths go in as arguments, so nothing in them is read as shell.
        let script = """
        while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
        rm -rf "$3.old"
        if mv "$3" "$3.old" && ditto "$2" "$3"; then rm -rf "$3.old"; else rm -rf "$3"; mv "$3.old" "$3"; fi
        xattr -dr com.apple.quarantine "$3" 2>/dev/null
        open "$3"
        rm -rf "$4"
        """
        let swap = Process()
        swap.executableURL = URL(fileURLWithPath: "/bin/sh")
        swap.arguments = ["-c", script, "perch-update", String(ProcessInfo.processInfo.processIdentifier), staged.path, appURL.path,
                          staged.deletingLastPathComponent().deletingLastPathComponent().path]
        try swap.run()
        NSApp.terminate(nil)
    }

    /// "0.4.0" is newer than "0.3.12": compared number by number.
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }
}
