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
| **Live activities** (closed notch) | Album art and an equalizer while music plays; the song title when the track changes; focus-timer countdown; volume and brightness HUD; charging; low battery (Mac and Bluetooth devices); upcoming events five minutes ahead; Bluetooth devices connecting; Shortcuts finishing. |
| **Two at once** | A second activity keeps a small glyph at the end of the right ear while another takes the notch: the timer's ring beside a notice or the song title, the album art beside the timer. |
| **Microphone** | ⌃⌥M, or **Mute Microphone** in the menu bar menu, mutes the mic in every app (by its mute control, or by turning its input level down when it has none). A red badge stays in the closed notch while it's muted. An on-air ring outlines the closed notch while a camera (green) or the mic (orange) is in use. |
| **Nook tab** | Media player for Apple Music and Spotify: artwork, scrubber, play/pause, next/previous, shuffle, repeat, favorite. Its accent color comes from the album art. Two configurable widgets beside it: Calendar, Mirror, Shortcuts, Focus timer, Batteries, Quick toggles or Notes. |
| **Tray tab** | Drag files toward the notch and it opens with drop zones: **Keep in Tray**, **AirDrop**, **Compress** and **Copy to…**. Tray items have Quick Look thumbnails, drag back out to any app, and survive relaunches. The right-click menu offers Open, Open With, Show in Finder, Copy, AirDrop, Share, Compress, Extract, Convert Image (PNG/JPEG/HEIC), Make Smaller, Copy to…, Move to… and Remove. Dropped images, links and text become files. |
| **Focus tab** | Pomodoro timer (focus, short and long breaks, sound, auto-start), Reminders (check off, add new) and a Notes scratchpad. |
| **Stats tab** | CPU (with a sparkline), memory, disk and network; battery levels for the Mac, AirPods (each bud and the case), keyboards, mice and more; quick toggles for Dark Mode, Keep Awake, Mute, Color Picker (copies the hex code), Screenshot and Sleep Display. |
| **Calendar** | A five-day strip; "in 12m" and "Now" labels; a Join button for Zoom, Meet, Teams, Webex and FaceTime links. |
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

Other apps can open the same links, for example
`dynotch://notify?text=Hello&tint=orange` or `dynotch://timer/start`.

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

## Permissions

Each permission is requested the first time you use the feature that needs it.
**Settings → Permissions** shows the status of each one.

| Permission | Used for |
|---|---|
| Automation: Music, Spotify | Track info, artwork and playback controls |
| Automation: System Events | The Dark Mode toggle |
| Calendar, Reminders | The Calendar and Reminders widgets |
| Camera | The Mirror widget (it's only on while you're looking at it) |
| Bluetooth | Battery levels of connected devices |

Grants survive rebuilds as long as the app is signed with the local identity (see
above). An ad hoc build may lose them.

## Limitations

- **Now Playing covers Apple Music and Spotify.** Since macOS 15.4, other players
  (browsers, Podcasts and so on) only report to the private MediaRemote framework, which
  macOS reserves for Apple-signed processes. Apps that show every player work around this
  by loading code into an Apple-signed binary. Dynotch doesn't do that.
- The volume and brightness HUD appears alongside the system one. Hiding the system HUD
  would mean intercepting media keys, which needs Accessibility access.
- The equalizer bars are decorative. Real audio levels would need screen-recording
  permission.
- The brightness HUD reads the built-in display's brightness through the private
  DisplayServices framework. If that's unavailable it stays quiet.
- Not included from MacNotch: AI translation, setup profiles, and Night Shift / True Tone
  toggles (the last two have no public API).

## Layout

```
Sources/Dynotch/
  App/        entry point, settings model, hot key, helpers
  Notch/      panel, geometry, shape, pointer handling, live activities, open/closed views
  Media/      Now Playing service (distributed notifications + AppleScript), player UI
  Calendar/   EventKit service, calendar and reminders widgets
  Tray/       tray store, file actions, tray UI and drop zones
  Widgets/    mirror, focus timer, notes, system stats, batteries, quick toggles, shortcuts
  HUD/        volume (CoreAudio) and brightness monitors
  Activities/ microphone and camera monitor
  Settings/   settings window and permissions page
  Debug/      snapshot renderer
Support/      Info.plist, app icon
scripts/      build script, icon generator
```

The notch panel is as large as the open notch but only accepts the mouse while the
pointer is over the visible shape. Everywhere else, clicks pass through to the apps
underneath. A global and a local event monitor track the pointer for hover, swipes and
file drags.
