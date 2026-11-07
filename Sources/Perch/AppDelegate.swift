import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: NotchController?
    private var env: AppEnvironment?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // One Perch at a time: a second copy (opened twice, or login item plus a manual launch)
        // would stack a second notch on top of the first.
        let me = NSRunningApplication.current
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0.processIdentifier != me.processIdentifier }) {
            NSLog("Perch is already running; quitting this copy")
            NSApp.terminate(nil)
            return
        }
        let env = AppEnvironment.live()
        self.env = env
        controller = NotchController(env: env)
        controller?.show()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Don't leave a `claude -p` running with nobody to read it.
        env?.prompt.cancel()
    }
}

/// Every model the notch shows, created once.
@MainActor
struct AppEnvironment {
    let state: NotchState
    let settings: AppSettings
    let claude: ClaudeModel
    let media: MediaHub
    let shelf: ShelfModel
    let calendar: CalendarModel
    let timer: FocusTimer
    let prompt: PromptModel

    var spotify: PlayerModel { media.players[0] }

    static func live() -> AppEnvironment {
        let settings = AppSettings()
        let state = NotchState(geometry: NotchGeometry.detect().geometry)
        let env = AppEnvironment(state: state, settings: settings, claude: ClaudeModel(), media: MediaHub(players: [PlayerModel(source: .spotify), PlayerModel(source: .music)]),
                                 shelf: ShelfModel(), calendar: CalendarModel(), timer: FocusTimer(), prompt: PromptModel())
        env.claude.onAlert = { [weak state] t in state?.push(t) }
        env.claude.finishAlertsEnabled = { settings.finishAlerts }
        env.calendar.onAlert = { [weak state] t in state?.push(t) }
        env.timer.onAlert = { [weak state] t in state?.push(t) }
        ShelfModel.onProblem = { [weak state] t in state?.push(t) }
        AutoPalette.shared.isActive = { settings.theme == .auto }
        AutoPalette.shared.explicitlyChosen = { settings.themeChosen }
        AutoPalette.shared.start()
        env.claude.start()
        env.media.start()
        env.calendar.start()
        return env
    }
}

extension View {
    func notchEnvironment(_ env: AppEnvironment) -> some View {
        self.environment(env.state)
            .environment(env.settings)
            .environment(env.claude)
            .environment(env.media)
            .environment(env.shelf)
            .environment(env.calendar)
            .environment(env.timer)
            .environment(env.prompt)
    }
}
