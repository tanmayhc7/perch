import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: NotchController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let env = AppEnvironment.live()
        controller = NotchController(env: env)
        controller?.show()
    }
}

/// Every model the notch shows, created once.
@MainActor
struct AppEnvironment {
    let state: NotchState
    let settings: AppSettings
    let claude: ClaudeModel
    let spotify: SpotifyModel
    let shelf: ShelfModel
    let calendar: CalendarModel
    let timer: FocusTimer
    let prompt: PromptModel

    static func live() -> AppEnvironment {
        let settings = AppSettings()
        let state = NotchState(geometry: NotchGeometry.detect().geometry)
        let env = AppEnvironment(state: state, settings: settings, claude: ClaudeModel(), spotify: SpotifyModel(),
                                 shelf: ShelfModel(), calendar: CalendarModel(), timer: FocusTimer(), prompt: PromptModel())
        env.claude.onAlert = { [weak state] t in state?.push(t) }
        env.claude.finishAlertsEnabled = { settings.finishAlerts }
        env.calendar.onAlert = { [weak state] t in state?.push(t) }
        env.timer.onAlert = { [weak state] t in state?.push(t) }
        env.claude.start()
        env.spotify.start()
        env.calendar.start()
        return env
    }
}

extension View {
    func notchEnvironment(_ env: AppEnvironment) -> some View {
        self.environment(env.state)
            .environment(env.settings)
            .environment(env.claude)
            .environment(env.spotify)
            .environment(env.shelf)
            .environment(env.calendar)
            .environment(env.timer)
            .environment(env.prompt)
    }
}
