# Dynotch

Dynotch turns the MacBook notch into a Dynamic Island–style hub, in the spirit of
[NotchNook](https://lo.cafe/notchnook) and [MacNotch](https://setapp.com/apps/macnotch).
Rest the pointer on the notch for a glance at what's live, and click it (or swipe down on the
trackpad) to open a panel with your music, files, calendar, a focus timer and more. ⌃⌥K opens a
command field for timers, notes, reminders, toggles and sums. When it's closed, live activities
show up beside the camera.

It's a native SwiftUI + AppKit app, about 22,800 lines of Swift, with no third-party
dependencies.

## Features

| | |
|---|---|
| **Notch shell** | Hover for a glance; click, trackpad swipe or ⌃⌥N to open; swipe up, Esc or move away to close; swipe sideways over the open notch to move between its tabs. Spring animations, haptics, hover grow. A virtual notch on Macs and displays without one, or just a faint line along the top edge that covers nothing and grows into the notch while something's showing, when you hover and when it opens (**Settings → Appearance → Virtual notch**). Choose the built-in display, the main display or all displays. |
| **Themes** | Settings → Appearance picks what the open notch is made of (black, or Liquid Glass on macOS 26 and later, which stays black along the top where it meets the camera), an accent color for the selected tab, selections and buttons, and how round its top and bottom corners are; the cards inside follow the bottom ones. The model notch at the top of the page shows each change. The closed notch stays black, so it blends with the camera housing, and with Reduce Transparency on in System Settings the open one does too. |
| **Live activities** (closed notch) | Album art and an equalizer while music plays; the song title when the track changes; focus-timer countdown; volume and brightness HUD; charging; low battery (Mac and Bluetooth devices); upcoming events five minutes ahead; Bluetooth devices connecting; Shortcuts finishing; a screenshot landing in the Tray; rain about to start; notifications from Messages, Mail, Slack and other apps (see [Notification peeks](#notification-peeks)). |
| **Two at once** | A second activity keeps a small glyph at the end of the right ear while another takes the notch: the mute badge, a timer's or a download's ring, the Focus that's on, or the album art. The main activity keeps the order above: notices, the song title, the timer that ends soonest, a download, then music. |
| **Microphone** | ⌃⌥M, or **Mute Microphone** in the menu bar menu, mutes the mic in every app (by its mute control, or by turning its input level down when it has none). A red badge stays in the closed notch while it's muted. An on-air ring outlines the closed notch while a camera (green) or the mic (orange) is in use. Like macOS's own indicator, it leaves out Siri listening for its name. |
| **Downloads** | A ring in the closed notch while files arrive in ~/Downloads: a real percentage for Safari, which records its progress, and the size so far for Chrome, Firefox and Opera, whose partial files only grow. A notice names the file when it's done, and an option puts finished downloads in the Tray. |
| **Focus** | The symbol of the Focus that's on, in its color, at the end of the right ear, and a notice when a Focus turns on or off, whether by hand or on a schedule. macOS only tells apps whether a Focus is on, so Dynotch reads which one from the Focus settings, which takes Full Disk Access. Without it, nothing shows. |
| **Glance** | Resting the pointer on the closed notch grows it into a glance at what's live, with a control or two: the track with play, pause and skip; the Pomodoro or a named timer with pause and +1 min; a meeting about to start with Join; a download; the last notice. With nothing live, it shows the date, the battery, the weather, the next event and the Tray, each a click from its tab. A click anywhere else on it, or a swipe down, opens the whole notch; a swipe up or moving away closes it. **Settings → General → Hover shows** brings back the old behavior, the whole notch on hover. |
| **Command field** | ⌃⌥K from anywhere, or **Type a command** in the open notch's header. Type `tea 4m` for a timer, `note Buy coffee` for a note, `remind Call Sam 5pm` for a reminder (the time comes out of the title, and a time that's passed means tomorrow), `dark`, `awake`, `mute`, `screenshot` or `sleep` for a toggle, a profile's name to switch to it, `run` and a shortcut's name to run it, `18% of 240` or `5 km to mi` for a sum or a conversion (Return copies the answer). It also finds notes and Tray files by what's in their names and text, and opens a tab by its name. With nothing typed, it suggests one of each. ↑ and ↓ pick a row, Return runs it, Escape clears what's typed and then leaves. |
| **Nook tab** | Media player for Apple Music and Spotify: artwork, the track and where it's playing, scrubber, a big play button, next/previous, shuffle, repeat, favorite (Apple Music; Spotify doesn't let other apps like songs) and the output picker, on a glow in the album art's color. Beside it, a stack of up to two widgets, one at a time: Calendar, Mirror, Shortcuts, Focus timer, Batteries, Quick toggles, Notes or Weather. The stack turns by itself to the calendar shortly before an event, the weather before rain and the batteries when one runs low; a swipe up or down over it, or the dots on its edge, turn it by hand. A card with more than it shows, like a long note or the batteries, scrolls first. |
| **Weather** | Current conditions and today's high and low from [Open-Meteo](https://open-meteo.com) (no account or key), for a city you search for in Settings or, if you allow it, where your Mac is. Temperatures follow the system's unit unless you pick Celsius or Fahrenheit. When rain is about to start, a heads-up appears in the closed notch, from Open-Meteo's 15-minute forecast where there is one. |
| **Tray tab** | Drag files toward the notch and it opens with drop zones: **Keep in Tray**, **AirDrop**, **Compress** and **Copy to…**. Tray items have Quick Look thumbnails and their sizes, drag back out to any app, and survive relaunches. Click one and press Space to preview it in Quick Look, as in Finder; the arrow keys move between items. The right-click menu offers Quick Look, Open, Open With, Show in Finder, Copy, AirDrop, Share, Compress, Extract, Convert Image (PNG/JPEG/HEIC), Make Smaller, Copy to…, Move to… and Remove. Dropped images, links and text become files, and the last tile, which takes whatever room the files leave, adds files from an Open panel. The toolbar AirDrops, shares, compresses or clears everything. New screenshots and screen recordings land in the Tray as macOS saves them, from whichever folder the Screenshot app uses. |
| **Capture** | ⌃⌥S, **Capture Screen** in the menu bar menu, the Control tab's Capture tile or `dynotch capture` freezes every display under a dimmed overlay, like Flameshot. Drag out a region, or click for the whole display; drag inside it to move it, or its eight handles to resize it, with its size shown beside it. A toolbar appears under the selection: Pencil, Line, Arrow, Rectangle, Ellipse, Marker (a wide highlighter stroke), Text (click to place, type in place, Return commits), Blur (pixelates what's under it) and Counter (numbered badges), picked by P, L, A, R, C, M, T, B and N, or S to go back to moving the selection; eight colors and a width from 1 to 16 points, which the text's size follows; ⌘Z and ⇧⌘Z undo and redo. Then **Copy** (⌘C) puts a PNG on the clipboard, **Save** (⌘S) writes a PNG into the folder the Screenshot app saves to, named as macOS names its own, so it lands in the Tray too, **Add to Tray** does that and opens the Tray, and **Pin** floats the capture above every window until Esc, ⌘W or its close glyph. Return does what **Settings → Tray** says: copy, save, or both. Esc cancels. The result is drawn at the display's scale, pixel for pixel what was on screen. Needs Screen Recording, asked for the first time. |
| **Focus tab** | Two cards. The first holds the Pomodoro timer (focus, short and long breaks, sound, auto-start) and the named timers; the second switches between Reminders (check off, add new) and Notes: several notes with Markdown checklists (click a box to tick it; Return continues the list), saved as `.md` files named after their first line. Pick a folder in iCloud Drive in Settings and they sync to your other Macs; changes made on disk show up right away. |
| **Timers** | Beside the Pomodoro, type "tea 4m", "eggs 90s", "nap 1h30" or "laundry 45" (a number on its own is minutes) to start a named timer; pause, resume or cancel it, and run a stopwatch. The closed notch shows the timer that ends soonest, the Pomodoro included, with the next one as a glyph beside it. At zero, a notice and a sound. |
| **Control tab** | Toggle tiles for Dark Mode, Keep Awake and muting the microphone, and for the color picker (copies the hex code), a screenshot (Dynotch's own capture, above) and sleeping the display. Wide sliders for the built-in display's brightness (where DisplayServices can set it) and the volume, with a mute button, and a menu of the Mac's outputs. Battery rings for the Mac, AirPods (each bud and the case), keyboards, mice and more, with paired devices that aren't connected listed underneath (headphones first) and a Connect button for each, scrolling when there are more than fit; right-click a connected device to disconnect it. CPU, memory and download speed along the bottom, with disk space and the upload speed in its tooltip. It was the Stats tab; links and scripts still call it `stats`. |
| **Audio and keys** | **Live equalizer** (opt-in, macOS 14.2 or later) makes the equalizer bars follow the music: a Core Audio process tap listens to Music or Spotify, only while it plays and some bars are on screen, and splits the sound into four bands. **Replace system HUD** (opt-in) takes over the volume, mute and brightness keys so only Dynotch's meter shows, in steps of a sixteenth (a sixty-fourth with ⇧⌥), even at either end of the range. Keys Dynotch can't handle, like an output without a volume control or an external display, go to macOS as usual. Swipe two fingers sideways over the closed notch, or over the open notch's header, to skip tracks (left for next, right for previous); over the rest of the open notch the same swipe moves between tabs. Scroll over the artwork in the Nook to change the volume. The output button beside the player lists the Mac's outputs (speakers, headphones, displays, Bluetooth) and switches the default output; AirPlay speakers and TVs come from AVKit's AirPlay picker in the same list. |
| **Calendar** | Up next: the next event in full, with "in 12m" or "until 11:00", its times and call service, a Join button for Zoom, Meet, Teams, Webex and FaceTime links, and Open in Calendar; the rest of the day underneath. After the day's last event, tomorrow's first. |
| **Profiles** | Saved setups such as Work, Home and Presenting. A profile keeps what the notch shows and how it opens: tabs, widgets, live activities (and which apps' notifications peek), size, theme and displays. Switch from the menu bar's **Profiles** menu, **Settings → General → Profiles**, or `dynotch profile Work`. The profile that's on keeps the changes you make. A profile can switch on by itself when a Focus turns on (a particular one, or any) or when an external display connects; when that Focus ends or the display goes, the notch goes back to how it was, unless you switched profiles by hand in between. Focus rules need Full Disk Access, like the Focus activity. |
| **App** | Menu bar icon, Settings window (General, Appearance, Live Activities, Nook & Widgets, Tray, Focus Timer, Permissions, About), launch at login, and a check for updates against the latest GitHub release that installs the new version in place and reopens Dynotch. Runs as an agent app with no Dock icon. |
| **Welcome tour** | On first launch, four short steps: how to open the notch and what shows beside the camera, what's new, the permissions worth allowing (each with its status and an Allow or Open System Settings button), and where things are. **Settings → About** and **Welcome Tour…** in the menu bar menu bring it back. |

## Install

Dynotch needs macOS 14 or later. It's made for MacBooks with a notch, and draws a virtual
one on displays without.

1. Download `Dynotch-<version>.dmg` from
   [Releases](https://github.com/ALIRAZA47/dynotch/releases/latest), or use the
   [GitHub CLI](https://cli.github.com):

   ```bash
   gh release download --repo ALIRAZA47/dynotch --pattern '*.dmg'
   ```

2. Open the DMG and drag **Dynotch** onto **Applications**.
3. Open Dynotch from Applications. It isn't notarized by Apple, so the first time, macOS
   says it can't check it for malicious software. Click **Done**, open **System Settings →
   Privacy & Security**, and under **Security** click **Open Anyway** next to the message
   about Dynotch. Or remove the download mark in Terminal instead:

   ```bash
   xattr -dr com.apple.quarantine /Applications/Dynotch.app
   ```

   A DMG fetched with `gh` doesn't carry that mark, so macOS doesn't ask.
4. Dynotch lives in the notch and the menu bar, with no Dock icon. On first launch the
   welcome tour walks through the permissions worth allowing; **Settings → Permissions**
   lists them all.

To use the `dynotch` command from Terminal, see [Scripting](#scripting).

**Updating.** **Check for Updates…** in the menu bar menu, or the **Updates** card in
**Settings → About**, asks GitHub for the newest release and says whether you have it. With
**Check automatically** on (it is, unless you turn it off), Dynotch asks once a day, a little
after launch, and a new version is announced in the notch. The check is one request to
`api.github.com` that carries nothing but the app's version. **Install and Relaunch** downloads the
release's zip, checks that the app inside is Dynotch, the version announced and newer, and
signed with the same certificate as the copy you have, puts it in place and reopens Dynotch,
which says so in the notch. Only the key that signs Dynotch's releases can make an app that
passes, so a tampered download is refused. Settings, notes, Tray files and the permissions you
gave it stay, as macOS sees the same app. A copy that can't replace itself, like one run
straight from the disk image, offers **Download** instead: it opens the new disk image in your
browser; then quit Dynotch from its menu bar icon and replace the app in Applications.

**Uninstalling.**

1. If **Launch at login** is on, turn it off in **Settings → General** first.
2. Quit Dynotch and move it from Applications to the Trash.
3. To remove what it saved as well (this deletes the notes and Tray files kept there):

   ```bash
   rm -rf ~/Library/Application\ Support/Dynotch
   defaults delete app.dynotch.Dynotch
   ```

   Notes you moved to iCloud Drive stay in its **Dynotch Notes** folder.
4. The permissions you gave it stay listed in **System Settings → Privacy & Security**
   until you remove them there.

## Build and run

Building needs the macOS 26 SDK, which the Glass theme compiles against, and its Swift toolchain:
Xcode 26 or later, or its Command Line Tools. What it builds runs on macOS 14 or later.

```bash
./scripts/build.sh
open build/Dynotch.app
```

`scripts/build.sh` builds a release binary, generates the app icon, assembles
`build/Dynotch.app` and signs it. Move the app to `/Applications` before
turning on **Launch at login**.

Run `./scripts/make-signing-identity.sh` once first. It creates a self-signed
"Dynotch Local Signing" certificate in a keychain of its own,
`~/Library/Keychains/dynotch-signing.keychain-db`, with a password you choose, and
`build.sh` signs with it, so macOS keeps Dynotch's permissions across rebuilds. That
keychain stays out of the keychain search list and locks when the Mac sleeps or an hour
after it was last used, so nothing else on the Mac can sign with the identity unnoticed;
`build.sh` asks for the password when it's locked. An identity an older version of the
script put in the login keychain is moved across, permissions intact. Without an identity,
the app is signed ad hoc, which looks like a new app to macOS after every build.

The app is signed with the hardened runtime, which keeps other processes from loading code
into it. `Support/Dynotch.entitlements` lists what it may still reach: the camera, location,
calendars and Apple events.

`./scripts/package.sh` builds and signs a release and puts `Dynotch-<version>.dmg` and a
`.zip` of the app in `dist/`, with their SHA-256 checksums. The version comes from
`Support/Info.plist`.

For development, `swift build` and `.build/debug/Dynotch` also work.
`Dynotch --snapshot <folder>` renders every notch state with sample data to PNGs,
which is handy for reviewing UI changes. `Dynotch --energy-probe` counts how often the polls
would run and wake the Mac in an hour, in each of the conditions under [Energy](#energy).
`Dynotch --capture-test` opens the capture editor over a made-up picture of each display, so
its tools can be tried without Screen Recording access, and `Dynotch --capture-self-test <folder>`
drives them with synthesized events off screen, prints a line per check and leaves the result there.

## Scripting

Dynotch answers `dynotch://` links, and `scripts/dynotch` wraps them for the shell.
The app carries a copy in `Dynotch.app/Contents/Resources/dynotch`; link it onto your
`PATH` to use it anywhere:

```bash
sudo ln -s /Applications/Dynotch.app/Contents/Resources/dynotch /usr/local/bin/dynotch
```

| Command | What it does |
|---|---|
| `dynotch notify "Deploy done" --detail "api · 2m 14s" --symbol checkmark.circle.fill --tint green` | Shows a notice in the closed notch. Long text moves to the row underneath. `--seconds` sets how long it stays (4 by default). The notice carries a small terminal badge, so it can't pass for one of Dynotch's own. |
| `dynotch open tray` | Opens the notch on a tab: `home`, `tray`, `focus` or `stats` (the Control tab). |
| `dynotch close` | Closes the notch. |
| `dynotch timer start` | Controls the focus timer: `start`, `pause`, `toggle`, `reset` or `skip`. |
| `dynotch tray --show report.pdf` | Adds files to the Tray, and opens it with `--show`. The items point at the files where they are, never copies; nothing under `~/Library` is taken; and the notch says what a script added. |
| `dynotch profile Work` | Switches to a saved profile by name. The notch says which, or that there's no such profile. |
| `dynotch capture` | Freezes the screen to capture a region, like ⌃⌥S. |

Other apps can open the same links, for example
`dynotch://notify?text=Hello&tint=orange`, `dynotch://timer/start`, `dynotch://profile?name=Work` or
`dynotch://capture`.

**When a long command finishes.** Source `notify-long-commands.zsh` (it sits next to
`dynotch` in the app) from `~/.zshrc`. Any command that runs for 30 seconds or more
then ends with a "Done" or "Failed" notice. `DYNOTCH_LONG_COMMAND` changes the threshold.
The notice names the command alone, `make` say, since its arguments can hold tokens;
`DYNOTCH_LONG_COMMAND_DETAIL=full` includes them.

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

**Settings → Live Activities → Notifications** chooses which apps peek. Peeks stay hidden
while a Focus is on and while a display is mirrored, as macOS's own banners do. Dynotch can't
tell when the screen is shared, so **Hide message text**, which shows only the app and the
sender, is worth turning on if you share it.

**Turning it on.** macOS has no public API for other apps' notifications, so Dynotch reads
them from Notification Center's own database
(`~/Library/Group Containers/group.com.apple.usernoted/db2/db`), which only apps with Full
Disk Access can open. In System Settings → Privacy & Security → Full Disk Access, turn on
Dynotch (add it with **+** if it isn't listed). macOS may ask you to quit and reopen Dynotch.

**System banners still appear.** Dynotch only reads notifications, so macOS keeps showing its
own banner for each one. To see only the peek for an app, open System Settings →
Notifications, choose the app and set its alert style to **None**. Leave **Show in
Notification Center** on, because that's where Dynotch reads them from.

**A few seconds behind.** macOS saves a notification to that database about five seconds after
it arrives, and holds off longer while the same app keeps sending, so a peek comes that much
after the system banner. Dynotch picks it up about 50 ms after macOS saves it.

**Trying it.** `osascript -e 'display notification "Hello" with title "Test"'` posts a
notification as Script Editor, which peeks with a bell while **Other apps** is on.

**Privacy.** The database is opened read-only. Dynotch shows a notification and forgets it:
nothing a notification says is logged or saved. The only thing it remembers is the time of
the newest notification it has seen, and only while it runs.

## Energy

Dynotch runs all day, so it keeps quiet when nobody's looking. While the displays sleep, the
screen is locked, the screen saver runs or another user has the Mac, nothing polls, and the notch
closes and takes its views off the screen, which stops their animations, the Control tab's sampling, the
Mirror's camera and the live equalizer's audio tap. Timers still end on time, with their sound.
When you're back, whatever came due meanwhile runs once.

On battery and in Low Power Mode, the polls run less often. Everything else (music, volume,
the microphone, notifications, files arriving) is driven by events, so it costs nothing until
something happens.

| Poll | On power | On battery | Low Power Mode |
|---|---|---|---|
| Control tab's system line, only while it's open | 1.5 s | 3 s | 5 s |
| Focus schedules | 30 s | 1 min | 2 min |
| Event alerts | 30 s | 45 s | 45 s |
| Bluetooth batteries (`system_profiler`) | 2 min | 5 min | 10 min |
| Weather | 10 min | 15 min | 20 min |
| The Screenshot app's save folder | 1 min | 2 min | 5 min |
| A download: moving, stalled, still for half an hour | 1 s, 10 s, 30 s | 2 s, 20 s, 1 min | 3 s, 30 s, 2 min |
| A running timer's countdown | 0.5 s | 0.5 s | 1 s |
| Update check, with **Check automatically** on | 24 h | 24 h | 24 h |

`Dynotch --energy-probe` measures this. With Focus, events, weather, Bluetooth and screenshots on,
the polls run 336 times an hour before these changes and about 310 on power (timers now get
leeway, so macOS runs them alongside other wakeups), 170 on battery, 120 in Low Power Mode, and
none while the displays sleep. The equalizer's bars bounce in Core Animation, which the window
server runs without waking the app, so the closed notch with music playing wakes it about once
every three seconds, the same as with nothing playing. Animated from SwiftUI, they woke it on
every frame of the display, 120 times a second. `Dynotch --energy-probe notch` measures just this.

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
| Screen Recording | Capture: freezing the screen to select a region. Asked for the first time you capture; after a refusal, **Settings → Permissions** opens its pane in System Settings |
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
- The brightness HUD and the Control tab's brightness slider reach the built-in display through
  the private DisplayServices framework. If that's unavailable, the HUD stays quiet and the slider
  isn't shown.
- Not included from MacNotch: AI translation, and Night Shift / True Tone toggles (they have
  no public API).
- Which Focus is on comes from Focus settings files that Apple doesn't document. A scheduled
  Focus switched off by hand is recognized by the record macOS keeps of what was switched off,
  using the key names in macOS's own Focus code, but that hasn't been checked against a real
  switch-off yet. If the notch shows a Focus that's off, **Settings → About → Diagnostics**
  saves a report of what the files hold, with names and places left out.
- Notification peeks read a database that Apple doesn't document. Its location and layout
  have changed between macOS versions before; if they change again, Settings says
  notifications can't be read on that Mac. They were last checked on macOS 27.0.1.

## Layout

```
Sources/Dynotch/
  App/        entry point, settings model, hot key, energy coordinator, helpers
  Notch/      panel, geometry, shape, pointer handling, live activities, open/closed views
  Media/      Now Playing service (distributed notifications + AppleScript), player UI
  Calendar/   EventKit service, calendar and reminders widgets
  Tray/       tray store, file actions, tray UI and drop zones, screenshot watcher, Quick Look
  Capture/    the screenshot tool: freezing the displays, the overlay and editor, Core Graphics rendering, pinned captures
  Widgets/    mirror, focus timer, notes, system stats, batteries, quick toggles, shortcuts, weather
  HUD/        volume (CoreAudio) and brightness monitors, media-key tap
  Notifications/  notification peeks: Notification Center reader, settings
  Activities/ microphone and camera, downloads, Focus
  Profiles/   saved setups and the rules that switch them
  Settings/   settings window and permissions page
  Welcome/    the first-run welcome tour
  Debug/      snapshot renderer, energy probe, capture self-test
Support/      Info.plist, entitlements, app icon
scripts/      build and signing scripts, icon generator, the dynotch command and the zsh hook
```

The notch panel is as large as the open notch but only accepts the mouse while the
pointer is over the visible shape. Everywhere else, clicks pass through to the apps
underneath. A global and a local event monitor track the pointer for hover, swipes and
file drags.
