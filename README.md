<p align="center"><img src="docs/images/icon.png" width="112" alt="Perch icon"></p>

<h1 align="center">Perch</h1>

<p align="center"><i>Perched on your MacBook's notch, keeping an eye on Claude Code.</i></p>

<p align="center">
Your MacBook's notch, turned into a live Claude Code dashboard,<br>
a Spotify and Apple Music remote, an AirDrop and file shelf, and a one-line Claude prompt.
</p>

<p align="center"><a href="docs/media/perch.mp4"><img src="docs/media/perch.gif" width="860" alt="Perch in 25 seconds: the notch lights up while Claude responds, springs open into a dashboard of tokens, burn rate and budget, answers a question typed into the Ask Claude bar, takes a dropped file for AirDrop or the shelf, swipes from Spotify to Apple Music, starts a 25-minute focus timer whose YouTube focus music takes over the music tile, then turns from the Auto theme to clear Glass with a sunset showing through"></a><br>
<sub>▶ <a href="docs/media/perch.mp4">Watch with sound</a> (25 s)</sub></p>

<p align="center"><img src="docs/images/expanded-ember.png" width="860" alt="Perch open: Claude Code usage with a budget ring, music now playing, the next meeting with a Join button, a focus timer and an Ask Claude bar"></p>

Perch sits in the notch and stays out of the way. Point at the notch and it springs open. While a Claude Code
session is responding, the notch glows softly so you can see it's working from any app.

## Features

### Claude Code at a glance
- Tokens for the **last 5 hours** and **today**, the estimated cost, and the **burn rate** with a 30-minute sparkline
- Your **all-sessions budget** as a ring, with how much is left
- Which sessions are **responding**, active or idle, by project folder
- A soft **glow** around the notch while any session is responding, with the live token count beside the notch
- **Alerts slide out of the notch** at 80% and 100% of your budget, when the burn rate runs high, and (optionally) when a session finishes

<p align="center"><img src="docs/images/collapsed-responding.png" width="760" alt="The closed notch while Claude responds: a spark and the streaming token count on the left, a focus timer on the right"></p>
<p align="center"><img src="docs/images/toast-budget.png" width="760" alt="A budget alert sliding out of the notch"></p>

These numbers come from [**token-meter**](https://github.com/tanmayhc7/claude-token-meter), a Claude Code plugin that
records each request's usage in `~/.claude/token-meter/`. Install it first; Perch only reads that folder.
Tokens are counted the way token-meter's budgets count them: cache reads weighted by their price.
Set a budget in Claude Code with `/token-budget all 5M` (or `/token-budget all $20`).

### Ask Claude from the notch
Type a question into the bar at the bottom and press Return. It runs `claude -p` with your own Claude Code login and
streams the answer into the notch. Pick **Haiku**, **Sonnet** or **Opus** from the chip; Haiku is the default because
it's the cheapest. The cost of each answer is shown next to it.

<p align="center"><img src="docs/images/answer.png" width="860" alt="An answer from Claude streamed into the notch"></p>

### Spotify and Apple Music
Track, artist, artwork and progress, with previous, play/pause and next. Spotify and Apple Music share one tile:
**swipe sideways with two fingers** (or click the dots in the corner) to switch, and the tile turns to whichever
app starts playing on its own. Perch never opens either app by itself; when one is closed its page shows an
**Open** button instead.

<p align="center"><img src="docs/images/music.png" width="860" alt="The music tile showing Apple Music, with page dots in its corner for switching back to Spotify"></p>

### Drop zone: AirDrop and a shelf
As soon as you start dragging files anywhere, a hint slides out of the notch. Drag them onto the notch and it opens into two targets:
- **AirDrop** sends them to a nearby device.
- **Shelf** holds them in the notch so you can drag them out later, into any app. Right-click a file for Open, Show in Finder, AirDrop or Remove.

The shelf keeps references to your files. It never copies, moves or uploads them.

<p align="center"><img src="docs/images/drag-hint.png" width="760" alt="While files are dragged, the notch says it takes drops"></p>
<p align="center"><img src="docs/images/drop.png" width="860" alt="Dragging files over the notch shows AirDrop and Shelf targets"></p>
<p align="center"><img src="docs/images/shelf.png" width="860" alt="Files held on the shelf, ready to drag out"></p>

### Next meeting
Your next event in the next 24 hours, with a **Join** button for Zoom, Google Meet, Teams, Webex, FaceTime and other
video links. Two minutes before it starts, a reminder with Join slides out of the notch. Calendar access is only
requested when you click **Show my calendar**.

**Which calendars.** Perch reads every calendar on your Mac and shows the earliest event across all of them, so iCloud,
Google, Outlook and Exchange calendars combine into one "next meeting". Choose which count under **⋯ → Calendars**,
where they're grouped by account with a checkmark each; a calendar you add later is included until you turn it off.
To bring in Google Calendar, add your Google account in System Settings → Internet Accounts and switch on Calendars
(**⋯ → Calendars → Add a Google or other account…** opens it). Nothing goes through Google directly: events are read
on your Mac by macOS.

### Focus timer
25, 50 or 5 minutes. The countdown ring sits beside the closed notch, and a chime plus a slide-out tell you when it's done.

**Do Not Disturb while it runs (optional).** Turn on **⋯ → Do Not Disturb during focus timer** and starting a timer
turns on Do Not Disturb; when it ends or you stop it, Perch turns it off and puts back the Focus you had on before
(Work, Personal, or none). If you switch Focus yourself during the timer, Perch leaves your choice alone.

macOS doesn't let apps change Focus directly, so this goes through two small shortcuts, **Perch Focus** and
**Perch Focus Off**. The first time you turn the option on, Perch opens them in the Shortcuts app; click
**Add Shortcut** on each. They only get and set your Focus, and you can read every step in Shortcuts.
Perch remembers a running session, so quitting Perch, a crash or sleep can't leave Do Not Disturb stuck on.

**Focus music (optional).** Under **⋯ → Focus music**, pick an audio file (mp3, m4a, wav, …) or paste a YouTube link
(a video or a live stream). It plays for as long as a 25 or 50 minute timer runs (a file loops), fading in when you
start or resume and out when you pause, stop or finish; breaks stay quiet. If Spotify or Apple Music is playing, Perch
pauses it first. The music gets its own page in the music tile, next to Spotify and Apple Music, where you can pause it
or stop it for the rest of the session while the timer keeps going.

YouTube needs a connection. If [Brave](https://brave.com) is installed, the video plays in a private, headless Brave
(its own profile, no window or Dock icon) whose Shields block YouTube's ads; otherwise it plays in a hidden web page
inside Perch, where ads still play (Perch presses Skip when YouTube offers it). The hidden page closes when the timer
ends, after two minutes paused (resuming reopens it where it was), and on its own if Perch quits unexpectedly.

### Themes
**Auto** (the default) takes its colours from your wallpaper, so the open notch blends into your desktop: it stays
black around the hardware notch and fades into the wallpaper's own colour toward its bottom edge, while the glow,
rings and buttons take the wallpaper's strongest colours, brightened to glow on black. It looks at the strip of wallpaper behind the menu bar,
and it follows you when you change wallpapers or switch to a Space with a different one. It reads the wallpaper file
only, so it needs no Screen Recording permission. For a dynamic or aerial wallpaper with no picture file, it uses
your Mac's accent colour.

<p align="center">
<img src="docs/images/auto-sunset.png" width="280" alt="Auto theme on a sunset wallpaper: orange accents">
<img src="docs/images/auto-ocean.png" width="280" alt="Auto theme on an ocean wallpaper: blue accents">
<img src="docs/images/auto-forest.png" width="280" alt="Auto theme on a forest wallpaper: green accents">
</p>

Or pick a fixed theme from the **⋯** menu: **Ember** (above), **Aurora** or **Graphite**.

<p align="center">
<img src="docs/images/expanded-aurora.png" width="420" alt="Aurora theme">
<img src="docs/images/expanded-graphite.png" width="420" alt="Graphite theme">
</p>

Macs without a notch get a small pill at the top center of the screen that works the same way.

## Install

1. Download `perch-<version>.zip` from the [latest release](https://github.com/tanmayhc7/perch/releases/latest) and unzip it.
2. Drag **Perch.app** into **Applications**.
3. Open it. macOS blocks it the first time, because the app isn't notarized by Apple yet (see [Signing](#signing-and-notarization)):
   - Click **Done** on the warning.
   - Open **System Settings → Privacy & Security**, scroll down to the message about Perch, and click **Open Anyway**.
   - Confirm with **Open Anyway** and your password.

   You only need to do this once. If you'd rather use Terminal: `xattr -dr com.apple.quarantine /Applications/Perch.app`
4. Point at the notch. To start it with your Mac, turn on **Open at login** in the **⋯** menu.

Requires macOS 14 Sonoma or later. The app is a universal binary (Apple Silicon and Intel).

There's no Dock icon. To quit, open the notch and choose **⋯ → Quit Perch**.

### Permissions it asks for
| When | Permission | Why |
| --- | --- | --- |
| First time Spotify is open | Automation → Spotify | To read the current track and play, pause and skip |
| First time Apple Music is open | Automation → Music | The same, for Apple Music |
| You click **Show my calendar** | Calendars | To show your next meeting |
| You turn on **Do Not Disturb during focus timer** | Adding two shortcuts in Shortcuts | To turn Do Not Disturb on and off for the timer |

You can turn any of these off in **System Settings → Privacy & Security** at any time.

## Build from source

You need the Xcode **Command Line Tools** (`xcode-select --install`) with Swift 5.10 or later. The full Xcode app isn't needed.

```bash
git clone https://github.com/tanmayhc7/perch.git
cd perch
./scripts/build-app.sh          # → dist/Perch.app and dist/perch-<version>.zip
open dist/Perch.app
```

Other useful commands:

```bash
swift run LedgerCheck                          # checks for the ledger reader
swift run Perch --snapshot docs/images   # re-render the README screenshots from sample data
```

### Project layout
| Path | What's there |
| --- | --- |
| `Sources/LedgerKit` | Reads token-meter's ledger and computes the stats. No UI code, so a menu-bar app or CLI can reuse it. |
| `Sources/Perch/NotchController.swift` | The borderless panel over the notch, hover and drag detection |
| `Sources/Perch/*Model*.swift` | Claude, music players, shelf, calendar, timer and prompt models; `AutoPalette.swift` picks the Auto theme's colours |
| `Sources/Perch/RootView.swift`, `ExpandedView.swift` | The SwiftUI views |
| `scripts/build-app.sh` | Builds a universal `.app` and the release zip with SwiftPM only |
| `scripts/focus-shortcut.py` | Generates and signs the two Focus shortcuts in `Resources/` |
| `Sources/Perch/FocusLink.swift` | Runs those shortcuts for the focus timer, with crash and sleep recovery |

## Privacy
- Everything stays on your Mac. Perch has no analytics, no telemetry and no server.
- It reads `~/.claude/token-meter/` (written by token-meter). It never reads your Claude Code conversations.
- Questions you type into the notch are sent to Anthropic by your own `claude` command, exactly as if you ran `claude -p` in Terminal, and they use your Claude Code plan or API credits.
- Spotify artwork is downloaded from Spotify's image servers. Nothing is sent to Spotify beyond what its own app already does. Apple Music artwork comes straight from the Music app.
- The Auto theme reads your wallpaper file on your Mac to pick colours. It doesn't capture your screen. If your wallpaper is in Desktop, Documents or Downloads, it's only read after you choose **Auto** in the menu yourself, because macOS asks permission for those folders.
- Calendar events are read on your Mac with Apple's EventKit and never leave it.
- The Focus option runs the two Perch shortcuts on your Mac with Apple's `shortcuts` command. They read and set your Focus and nothing else.
- Files on the shelf are only referenced, never copied or uploaded. AirDrop uses macOS's own AirDrop sheet.

## Signing and notarization
Releases are currently **ad-hoc signed and not notarized**, which is why macOS asks you to approve the app once.
Notarizing needs a paid Apple Developer account. When one is available, the release steps become:

1. Sign with a Developer ID certificate and the hardened runtime:
   `codesign --force --options runtime --timestamp --sign "Developer ID Application: <Name> (<TEAMID>)" dist/Perch.app`
2. Zip and submit for notarization:
   `ditto -c -k --keepParent dist/Perch.app perch.zip`
   `xcrun notarytool submit perch.zip --apple-id <id> --team-id <TEAMID> --password <app-specific-password> --wait`
3. Staple the ticket and re-zip: `xcrun stapler staple dist/Perch.app`

`notarytool` and `stapler` ship with Xcode, so this step needs Xcode or a CI runner that has it.

## Roadmap
- A menu-bar version of the Claude stats (sharing `LedgerKit`)
- An estimate of claude.ai chat usage next to Claude Code's
- Signed and notarized releases, and Homebrew

## Credits
Made by [@tanmayhc7](https://github.com/tanmayhc7). Perch is an independent project and isn't affiliated with or
endorsed by Anthropic, Spotify or Apple. Copyright © 2026 Tanmay Chandavarkar. Released under the [GNU Affero General Public License v3.0](LICENSE) (AGPL-3.0): you can use, change and share it, but if you distribute a modified version, or run one for others over a network, you must publish its source under the same license.
