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
        // Nor Do Not Disturb on with no timer to turn it off.
        env?.focus.finishBeforeQuit()
        env?.music.stopBeforeQuit()
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
    let focus: FocusLink
    let music: FocusMusic
    let updater: Updater
    let widgets: WidgetHub

    var spotify: PlayerModel { media.players[0] }

    static func live() -> AppEnvironment {
        let settings = AppSettings()
        let state = NotchState(geometry: NotchGeometry.detect().geometry)
        let env = AppEnvironment(state: state, settings: settings, claude: ClaudeModel(), media: MediaHub(players: [PlayerModel(source: .spotify), PlayerModel(source: .music)]),
                                 shelf: ShelfModel(), calendar: CalendarModel(), timer: FocusTimer(), prompt: PromptModel(), focus: FocusLink(), music: FocusMusic(), updater: Updater(), widgets: WidgetHub())
        env.claude.onAlert = { [weak state] t in state?.push(t) }
        env.claude.finishAlertsEnabled = { settings.finishAlerts }
        env.calendar.onAlert = { [weak state] t in state?.push(t) }
        env.timer.onAlert = { [weak state] t in state?.push(t) }
        env.updater.onAlert = { [weak state] t in state?.push(t) }
        env.updater.noticesOn = { settings.updateNotices }
        // A little after launch, so it never slows the start.
        Task { @MainActor in try? await Task.sleep(for: .seconds(20)); env.updater.checkQuietly() }
        env.widgets.isOn = { settings.isOn($0) }
        env.widgets.onAlert = { [weak state] t in state?.push(t) }
        env.widgets.start()
        ShelfModel.onProblem = { [weak state] t in state?.push(t) }
        env.focus.onAlert = { [weak state] t in state?.push(t) }
        env.focus.isEnabled = { settings.focusDND }
        env.timer.onBegan = { [weak focus = env.focus, weak music = env.music, weak timer = env.timer] end in
            focus?.begin(endsAt: end)
            music?.begin(label: timer?.label ?? "Focus")
        }
        env.timer.onPaused = { [weak music = env.music] in music?.pause() }
        env.timer.onEnded = { [weak focus = env.focus, weak music = env.music] in focus?.finish(); music?.end() }
        env.music.onAlert = { [weak state] t in state?.push(t) }
        // A Brave left playing YouTube focus music by a crash: end it.
        BravePage.sweep()
        // Don't play on top of Spotify or Apple Music.
        env.music.onWillPlay = { [weak media = env.media] in
            media?.players.filter(\.playing).forEach { $0.playPause() }
            media?.selectedID = FocusMusic.pageID
        }
        env.focus.start()
        introduceAutoTheme(settings: settings, state: state)
        AutoPalette.shared.isActive = { settings.theme.followsWallpaper }
        AutoPalette.shared.explicitlyChosen = { settings.themeChosen }
        AutoPalette.shared.start()
        env.claude.start()
        env.media.start()
        env.calendar.start()
        return env
    }
}

/// People who picked a theme before Auto existed keep it, so they'd never see Auto. Tell them once.
@MainActor private func introduceAutoTheme(settings: AppSettings, state: NotchState) {
    let d = UserDefaults.standard
    guard !settings.theme.followsWallpaper, !d.bool(forKey: "autoThemeIntroduced") else { return }
    d.set(true, forKey: "autoThemeIntroduced")
    // A few seconds in, so it doesn't fight the launch.
    DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak settings, weak state] in
        state?.push(Toast(symbol: "paintpalette.fill", tint: .accent, title: "New: Auto theme",
                          subtitle: "Perch can take its colours from your wallpaper", actionTitle: "Try it",
                          action: { settings?.theme = .auto }, seconds: 12))
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
            .environment(env.focus)
            .environment(env.music)
            .environment(env.updater)
            .environment(env.widgets)
    }
}
