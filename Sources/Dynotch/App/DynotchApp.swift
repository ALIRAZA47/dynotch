import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

@main
enum DynotchApp {
    static func main() {
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            let delegate = AppDelegate()
            app.delegate = delegate
            app.setActivationPolicy(.accessory)
            withExtendedLifetime(delegate) { app.run() }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var hotKey: HotKey?
    private var muteHotKey: HotKey?
    private let profilesMenu = NSMenu(title: "Profiles")
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--snapshot") {
            let folder = arguments.count > index + 1 ? arguments[index + 1] : FileManager.default.currentDirectoryPath
            SnapshotRenderer.render(into: URL(fileURLWithPath: folder))
            NSApp.terminate(nil)
            return
        }

        NSApp.mainMenu = Self.makeMainMenu()
        // First, so a profile a rule picks is in place before the services read their settings.
        ProfileStore.shared.start()
        TrayStore.shared.load()
        NotesStore.shared.start()
        NowPlayingService.shared.start()
        PowerMonitor.shared.start()
        CalendarService.shared.start()
        VolumeMonitor.shared.start()
        BrightnessMonitor.shared.start()
        MediaKeyTap.shared.start()
        AudioOutputs.shared.start()
        AudioLevels.shared.start()
        DeviceBatteryMonitor.shared.start()
        MicMonitor.shared.start()
        DownloadMonitor.shared.start()
        FocusMonitor.shared.start()
        WeatherService.shared.start()
        LiveActivityCenter.shared.start()
        NotificationMirror.shared.start()
        NotchManager.shared.start()
        // Last, since reading the screenshot folder can bring up macOS's folder-access prompt.
        ScreenshotWatcher.shared.start()

        let settings = AppSettings.shared
        settings.$showMenuBarIcon
            .sink { [weak self] visible in self?.setStatusItemVisible(visible) }
            .store(in: &cancellables)
        settings.$globalShortcut
            .sink { [weak self] enabled in
                self?.hotKey?.unregister()
                self?.hotKey = enabled
                    ? HotKey(keyCode: kVK_ANSI_N, modifiers: controlKey | optionKey) { NotchManager.shared.toggle() }
                    : nil
            }
            .store(in: &cancellables)
        settings.$micShortcut
            .sink { [weak self] enabled in
                self?.muteHotKey?.unregister()
                self?.muteHotKey = enabled
                    ? HotKey(keyCode: kVK_ANSI_M, modifiers: controlKey | optionKey) { MicMonitor.shared.toggleMute() }
                    : nil
            }
            .store(in: &cancellables)

        if !settings.hasLaunchedBefore {
            settings.hasLaunchedBefore = true
            WelcomeWindowController.shared.show()
        }
    }

    /// Opening the app again from Finder or Spotlight shows its settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindowController.shared.show()
        return false
    }

    /// dynotch:// links from `scripts/dynotch`, shell hooks and other apps.
    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach(URLCommands.handle)
    }

    // MARK: Menu bar

    private func setStatusItemVisible(_ visible: Bool) {
        if visible, statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.image = Self.statusImage()
            item.button?.toolTip = "Dynotch"
            item.menu = makeStatusMenu()
            statusItem = item
        } else if !visible, let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    private func makeStatusMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("Open Notch", #selector(openNotch), key: "n", modifiers: [.control, .option]))
        menu.addItem(item("Open Tray", #selector(openTray)))
        menu.addItem(item("Start Focus Timer", #selector(startTimer)))
        menu.addItem(item("Mute Microphone", #selector(toggleMicMute), key: "m", modifiers: [.control, .option]))
        let profiles = NSMenuItem(title: "Profiles", action: nil, keyEquivalent: "")
        profilesMenu.delegate = self
        profiles.submenu = profilesMenu
        menu.addItem(profiles)
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(openSettings), key: ","))
        menu.addItem(item("About Dynotch", #selector(openAbout)))
        menu.addItem(item("Welcome Tour…", #selector(openWelcome)))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Dynotch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    private func item(_ title: String, _ action: Selector, key: String = "", modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        return item
    }

    @objc private func openNotch() { NotchManager.shared.open(tab: .home) }
    @objc private func openTray() { NotchManager.shared.open(tab: .tray) }
    @objc private func openSettings() { SettingsWindowController.shared.show() }
    @objc private func openAbout() { SettingsWindowController.shared.show(page: .about) }
    @objc private func openWelcome() { WelcomeWindowController.shared.show() }

    @objc private func startTimer() {
        PomodoroTimer.shared.start()
    }

    @objc private func toggleMicMute() {
        MicMonitor.shared.toggleMute()
    }

    @objc private func chooseProfile(_ sender: NSMenuItem) {
        let store = ProfileStore.shared
        guard let id = sender.representedObject as? UUID, let profile = store.profiles.first(where: { $0.id == id }) else { return }
        store.switchTo(profile)
    }

    @objc private func openProfileSettings() {
        ProfileStore.shared.revealRequested = true
        SettingsWindowController.shared.show(page: .general)
    }

    /// A tiny screen with a notch, drawn as a template so it follows the menu bar's color.
    private static func statusImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 14), flipped: true) { rect in
            let screen = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1.5), xRadius: 2.5, yRadius: 2.5)
            screen.lineWidth = 1.4
            NSColor.black.setStroke()
            screen.stroke()
            let notch = NSBezierPath(roundedRect: NSRect(x: rect.midX - 3.5, y: 1.5, width: 7, height: 3.5), xRadius: 1.5, yRadius: 1.5)
            NSColor.black.setFill()
            notch.fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    /// The app is never frontmost, but text fields in the notch still need the standard
    /// editing shortcuts, which AppKit finds through the main menu.
    private static func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Quit Dynotch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: "Window")
        window.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        windowItem.submenu = window
        main.addItem(windowItem)
        return main
    }
}

extension AppDelegate: NSMenuItemValidation {
    /// Ticks Mute Microphone while the mic is muted, and shows ⌃⌥M only while that shortcut is on.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(toggleMicMute) else { return true }
        let mic = MicMonitor.shared
        menuItem.state = mic.isMuted ? .on : .off
        menuItem.keyEquivalent = AppSettings.shared.micShortcut ? "m" : ""
        return mic.hasInput
    }
}

extension AppDelegate: NSMenuDelegate {
    /// Builds the Profiles submenu as it opens: each profile, with a tick by the one that's on.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === profilesMenu else { return }
        menu.removeAllItems()
        let store = ProfileStore.shared
        if store.profiles.isEmpty {
            menu.addItem(NSMenuItem(title: "No Profiles Yet", action: nil, keyEquivalent: ""))
        }
        for profile in store.profiles {
            let entry = item(profile.name, #selector(chooseProfile(_:)))
            entry.representedObject = profile.id
            entry.state = profile.id == store.activeID ? .on : .off
            entry.image = NSImage(systemSymbolName: profile.symbol, accessibilityDescription: nil)
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        menu.addItem(item(store.profiles.isEmpty ? "Save a Profile…" : "Profile Settings…", #selector(openProfileSettings)))
    }
}
