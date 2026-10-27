# Dynotch

Dynotch turns the MacBook notch into a Dynamic Island–style hub, in the spirit of
[NotchNook](https://lo.cafe/notchnook) and [MacNotch](https://setapp.com/apps/macnotch).
Hover the notch (or swipe down on the trackpad) and it opens into a panel with
your music, files, calendar, a focus timer and more. When it's closed, live activities
show up beside the camera.

It's a native SwiftUI + AppKit app, about 5,800 lines of Swift, with no third-party
dependencies.

## Features

| | |
|---|---|
| **Notch shell** | Hover, click, trackpad swipe or ⌃⌥N to open; swipe up, Esc or move away to close. Spring animations, haptics, hover grow. A virtual notch on Macs and displays without one. Choose the built-in display, the main display or all displays. |
| **Live activities** (closed notch) | Album art and an equalizer while music plays; the song title when the track changes; focus-timer countdown; volume and brightness HUD; charging; low battery (Mac and Bluetooth devices); upcoming events five minutes ahead; Bluetooth devices connecting; Shortcuts finishing; a screenshot landing in the Tray; rain about to start; notifications from Messages, Mail, Slack and other apps (see [Notification peeks](#notification-peeks)). |
| **Two at once** | A second activity keeps a small glyph at the end of the right ear while another takes the notch: the mute badge, a timer's or a download's ring, the Focus that's on, or the album art. The main activity keeps the order above: notices, the song title, the timer that ends soonest, a download, then music. |
| **Microphone** | ⌃⌥M, or **Mute Microphone** in the menu bar menu, mutes the mic in every app (by its mute control, or by turning its input level down when it has none). A red badge stays in the closed notch while it's muted. An on-air ring outlines the closed notch while a camera (green) or the mic (orange) is in use. |
| **Downloads** | A ring in the closed notch while files arrive in ~/Downloads: a real percentage for Safari, which records its progress, and the size so far for Chrome, Firefox and Opera, whose partial files only grow. A notice names the file when it's done, and an option puts finished downloads in the Tray. |
| **Focus** | The symbol of the Focus that's on, in its color, at the end of the right ear, and a notice when a Focus turns on or off, whether by hand or on a schedule. macOS only tells apps whether a Focus is on, so Dynotch reads which one from the Focus settings, which takes Full Disk Access. Without it, nothing shows. |
| **Nook tab** | Media player for Apple Music and Spotify: artwork, scrubber, play/pause, next/previous, shuffle, repeat, favorite. Its accent color comes from the album art. Two configurable widgets beside it: Calendar, Mirror, Shortcuts, Focus timer, Batteries, Quick toggles, Notes or Weather. |
| **Weather** | Current conditions and today's high and low from [Open-Meteo](https://open-meteo.com) (no account or key), for a city you search for in Settings or, if you allow it, where your Mac is. Temperatures follow the system's unit unless you pick Celsius or Fahrenheit. When rain is about to start, a heads-up appears in the closed notch, from Open-Meteo's 15-minute forecast where there is one. |
| **Tray tab** | Drag files toward the notch and it opens with drop zones: **Keep in Tray**, **AirDrop**, **Compress** and **Copy to…**. Tray items have Quick Look thumbnails, drag back out to any app, and survive relaunches. Click one and press Space to preview it in Quick Look, as in Finder; the arrow keys move between items. The right-click menu offers Quick Look, Open, Open With, Show in Finder, Copy, AirDrop, Share, Compress, Extract, Convert Image (PNG/JPEG/HEIC), Make Smaller, Copy to…, Move to… and Remove. Dropped images, links and text become files. New screenshots and screen recordings land in the Tray as macOS saves them, from whichever folder the Screenshot app uses. |
| **Focus tab** | Pomodoro timer (focus, short and long breaks, sound, auto-start), Reminders (check off, add new) and Notes: several notes with Markdown checklists (click a box to tick it; Return continues the list), saved as `.md` files named after their first line. Pick a folder in iCloud Drive in Settings and they sync to your other Macs; changes made on disk show up right away. |
| **Timers** | Beside the Pomodoro, type "tea 4m", "eggs 90s", "nap 1h30" or "laundry 45" (a number on its own is minutes) to start a named timer; pause, resume or cancel it, and run a stopwatch. The closed notch shows the timer that ends soonest, the Pomodoro included, with the next one as a glyph beside it. At zero, a notice and a sound. |
| **Stats tab** | CPU (with a sparkline), memory, disk and network; battery levels for the Mac, AirPods (each bud and the case), keyboards, mice and more, with paired devices that aren't connected listed underneath (headphones first) and a Connect button for each; right-click a connected device to disconnect it; quick toggles for Dark Mode, Keep Awake, Mute, Color Picker (copies the hex code), Screenshot and Sleep Display. |
| **Audio and keys** | **Live equalizer** (opt-in, macOS 14.2 or later) makes the equalizer bars follow the music: a Core Audio process tap listens to Music or Spotify, only while it plays and some bars are on screen, and splits the sound into four bands. **Replace system HUD** (opt-in) takes over the volume, mute and brightness keys so only Dynotch's meter shows, in steps of a sixteenth (a sixty-fourth with ⇧⌥), even at either end of the range. Keys Dynotch can't handle, like an output without a volume control or an external display, go to macOS as usual. Swipe two fingers sideways over the notch to skip tracks (left for next, right for previous), and scroll over the artwork in the Nook to change the volume. The output button beside the player lists the Mac's outputs (speakers, headphones, displays, Bluetooth) and switches the default output; AirPlay speakers and TVs come from AVKit's AirPlay picker in the same list. |
| **Calendar** | A five-day strip; "in 12m" and "Now" labels; a Join button for Zoom, Meet, Teams, Webex and FaceTime links. |
| **Profiles** | Saved setups such as Work, Home and Presenting. A profile keeps what the notch shows and how it opens: tabs, widgets, live activities (and which apps' notifications peek), size and displays. Switch from the menu bar's **Profiles** menu, **Settings → General → Profiles**, or `dynotch profile Work`. The profile that's on keeps the changes you make. A profile can switch on by itself when a Focus turns on (a particular one, or any) or when an external display connects; when that Focus ends or the display goes, the notch goes back to how it was, unless you switched profiles by hand in between. Focus rules need Full Disk Access, like the Focus activity. |
| **App** | Menu bar icon, Settings window (General, Appearance, Live Activities, Nook & Widgets, Tray, Focus Timer, Permissions, About), launch at login. Runs as an agent app with no Dock icon. |

## Build and run

Requires macOS 14 or later and the Swift toolchain (Xcode or the Command Line Tools).

```bash
./scripts/build.sh
open build/Dynotch.app
```

`scripts/build.sh` builds a release binary, generates the app icon, assembles
`build/Dynotch.app` and signs it. Move the app to `/Applications` before
turning on **Launch at login**.

Run `./scripts/make-signing-identity.sh` once first. It creates a self-signed
"Dynotch Local Signing" certificate in your login keychain, and `build.sh` signs
with it, so macOS keeps Dynotch's permissions across rebuilds. Without it, the
app is signed ad hoc, which looks like a new app to macOS after every build.

For development, `swift build` and `.build/debug/Dynotch` also work.
`Dynotch --snapshot <folder>` renders every notch state with sample data to PNGs,
which is handy for reviewing UI changes.

## Scripting

Dynotch answers `dynotch://` links, and `scripts/dynotch` wraps them for the shell.
The app carries a copy in `Dynotch.app/Contents/Resources/dynotch`; link it onto your
`PATH` to use it anywhere:

```bash
ln -s /Applications/Dynotch.app/Contents/Resources/dynotch /usr/local/bin/dynotch
```

| Command | What it does |
|---|---|
| `dynotch notify "Deploy done" --detail "api · 2m 14s" --symbol checkmark.circle.fill --tint green` | Shows a notice in the closed notch. Long text moves to the row underneath. `--seconds` sets how long it stays (4 by default). |
| `dynotch open tray` | Opens the notch on a tab: `home`, `tray`, `focus` or `stats`. |
| `dynotch close` | Closes the notch. |
| `dynotch timer start` | Controls the focus timer: `start`, `pause`, `toggle`, `reset` or `skip`. |
| `dynotch tray --show report.pdf` | Adds files to the Tray, and opens it with `--show`. |
| `dynotch profile Work` | Switches to a saved profile by name. The notch says which, or that there's no such profile. |

Other apps can open the same links, for example
`dynotch://notify?text=Hello&tint=orange`, `dynotch://timer/start` or `dynotch://profile?name=Work`.

**When a long command finishes.** Source `notify-long-commands.zsh` (it sits next to
`dynotch` in the app) from `~/.zshrc`. Any command that runs for 30 seconds or more
then ends with a "Done" or "Failed" notice. `DYNOTCH_LONG_COMMAND` changes the threshold.

**When Claude Code needs you.** Claude Code hooks can call the same command. Add this
to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "Notification": [{ "hooks": [{ "type": "command", "command": "dynotch notify 'Claude needs you' --symbol bubble.left.fill --tint orange" }] }],
    "Stop": [{ "hooks": [{ "type": "command", "command": "dynotch notify 'Claude is done' --symbol checkmark.circle.fill --tint green" }] }]
  }
}
```

## Notification peeks

When a notification arrives, it slides out of the closed notch: the app's symbol, who it's
from, and a line of text. Messages, Mail, Slack, Microsoft Teams, Outlook, WhatsApp, Telegram,
Signal, Discord, FaceTime, Zoom, Calendar and Reminders have symbols of their own; other apps
get a bell, and the line starts with the app's name.

**Settings → Live Activities → Notifications** chooses which apps peek. **Hide message text**
shows only the app and the sender, which is worth turning on if you share your screen: Dynotch
doesn't check Focus or screen sharing.

**Turning it on.** macOS has no public API for other apps' notifications, so Dynotch reads
them from Notification Center's own database
(`~/Library/Group Containers/group.com.apple.usernoted/db2/db`), which only apps with Full
Disk Access can open. In System Settings → Privacy & Security → Full Disk Access, turn on
Dynotch (add it with **+** if it isn't listed). macOS may ask you to quit and reopen Dynotch.

**System banners still appear.** Dynotch only reads notifications, so macOS keeps showing its
own banner for each one. To see only the peek for an app, open System Settings →
Notifications, choose the app and set its alert style to **None**. Leave **Show in
Notification Center** on, because that's where Dynotch reads them from.

**Privacy.** The database is opened read-only. Dynotch shows a notification and forgets it:
nothing a notification says is logged or saved. The only thing it remembers is the time of
the newest notification it has seen, and only while it runs.

## Permissions

Each permission is requested the first time you use the feature that needs it.
**Settings → Permissions** shows the status of each one.

| Permission | Used for |
|---|---|
| Automation: Music, Spotify | Track info, artwork and playback controls |
| Automation: System Events | The Dark Mode toggle |
| Calendar, Reminders | The Calendar and Reminders widgets |
| Camera | The Mirror widget (it's only on while you're looking at it) |
| Accessibility | Replace system HUD: handling the volume and brightness keys. Asked for when you turn it on |
| System audio recording | Live equalizer: hearing what Music or Spotify plays. Nothing is recorded. Asked for when you turn it on |
| Bluetooth | Battery levels of connected devices, and connecting or disconnecting paired ones |
| Downloads folder | Download progress in the closed notch, and finished downloads in the Tray |
| Full Disk Access | Notification peeks, and which Focus is on. There's no prompt for this one; **Settings → Permissions** opens its pane in System Settings. |
| Location (optional) | Weather where your Mac is, if you turn on Use My Location instead of picking a city |
| Desktop, Documents or Downloads folder | Adding new screenshots to the Tray (macOS asks for the folder screenshots are saved to), and notes kept in a folder you chose there |

Grants survive rebuilds as long as the app is signed with the local identity (see
above). An ad hoc build may lose them.

## Limitations

- **Now Playing covers Apple Music and Spotify.** Since macOS 15.4, other players
  (browsers, Podcasts and so on) only report to the private MediaRemote framework, which
  macOS reserves for Apple-signed processes. Apps that show every player work around this
  by loading code into an Apple-signed binary. Dynotch doesn't do that.
- The volume and brightness HUD appears alongside the system one unless **Replace system HUD**
  is on (Settings → Live Activities), which needs Accessibility access.
- The equalizer bars are decorative unless **Live equalizer** is on (Settings → Live
  Activities). That needs macOS 14.2 or later and the System Audio Recording permission, and
  follows Music and Spotify only. macOS has no public API to check that permission, so Dynotch
  asks the private TCC framework, as other audio tools do.
- The brightness HUD reads the built-in display's brightness through the private
  DisplayServices framework. If that's unavailable it stays quiet.
- Not included from MacNotch: AI translation, and Night Shift / True Tone toggles (they have
  no public API).
- Notification peeks read a database that Apple doesn't document. Its location and layout
  have changed between macOS versions before; if they change again, Settings says
  notifications can't be read on that Mac.

## Layout

```
Sources/Dynotch/
  App/        entry point, settings model, hot key, helpers
  Notch/      panel, geometry, shape, pointer handling, live activities, open/closed views
  Media/      Now Playing service (distributed notifications + AppleScript), player UI
  Calendar/   EventKit service, calendar and reminders widgets
  Tray/       tray store, file actions, tray UI and drop zones, screenshot watcher, Quick Look
  Widgets/    mirror, focus timer, notes, system stats, batteries, quick toggles, shortcuts, weather
  HUD/        volume (CoreAudio) and brightness monitors, media-key tap
  Notifications/  notification peeks: Notification Center reader, settings
  Activities/ microphone and camera, downloads, Focus
  Profiles/   saved setups and the rules that switch them
  Settings/   settings window and permissions page
  Debug/      snapshot renderer
Support/      Info.plist, app icon
scripts/      build script, icon generator
```

The notch panel is as large as the open notch but only accepts the mouse while the
pointer is over the visible shape. Everywhere else, clicks pass through to the apps
underneath. A global and a local event monitor track the pointer for hover, swipes and
file drags.
