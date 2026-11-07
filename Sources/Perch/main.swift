import AppKit

// `Perch --snapshot <dir>` renders the README screenshots from sample data and exits.
let args = CommandLine.arguments
if let i = args.firstIndex(of: "--snapshot") {
    let dir = i + 1 < args.count ? args[i + 1] : "docs/images"
    MainActor.assumeIsolated { Snapshots.render(to: URL(fileURLWithPath: dir)) }
    exit(0)
}

if let i = args.firstIndex(of: "--snapshot-bare"), i + 1 < args.count {
    MainActor.assumeIsolated { Snapshots.renderBare(to: URL(fileURLWithPath: args[i + 1])) }
    exit(0)
}

if let i = args.firstIndex(of: "--icon"), i + 1 < args.count {
    MainActor.assumeIsolated { IconRenderer.render(to: URL(fileURLWithPath: args[i + 1])) }
    exit(0)
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
