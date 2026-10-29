import SwiftUI

/// Profiles on the General page: the saved setups, which one is on, what switches each one on,
/// and saving the setup you have now as a new one.
struct ProfilesSection: View {
    @ObservedObject private var store = ProfileStore.shared

    private static let anchor = "profiles"

    var body: some View {
        ScrollViewReader { proxy in
            SettingsSection(title: "Profiles", trailing: store.active.map { "\($0.name) is on" },
                            footer: "A profile keeps what the notch shows and how it opens: tabs, widgets, live activities, size, theme and displays. Changes you make go into the profile that's on. When a profile's Focus ends or its display is unplugged, the notch goes back to how it was.") {
                SettingsCard {
                    if store.profiles.isEmpty {
                        IntroRow()
                        CardDivider()
                    }
                    ForEach(store.profiles) { profile in
                        ProfileRow(profile: profile, isActive: profile.id == store.activeID)
                        CardDivider()
                    }
                    NewProfileRow()
                }
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: store.profiles.map(\.id))
            }
            .id(Self.anchor)
            .onAppear { reveal(with: proxy) }
            .onChange(of: store.revealRequested) { reveal(with: proxy) }
        }
    }

    /// Scrolls the section into view when the menu bar menu asked for it.
    private func reveal(with proxy: ScrollViewProxy) {
        guard store.revealRequested else { return }
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.9)) { proxy.scrollTo(Self.anchor, anchor: .top) }
            store.revealRequested = false
        }
    }
}

/// What profiles are, before there are any.
private struct IntroRow: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            SymbolBadge(symbol: "square.stack.3d.up.fill", tint: Palette.lavender, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("Keep a setup for each part of your day")
                    .font(.system(size: 13, weight: .medium))
                Text("Work, Home, Presenting: a profile switches the notch's tabs, widgets and live activities together, from the menu bar, a dynotch:// link, or by itself when a Focus turns on or a display connects.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

private struct ProfileRow: View {
    let profile: Profile
    let isActive: Bool
    @ObservedObject private var store = ProfileStore.shared
    @ObservedObject private var focus = FocusMonitor.shared
    @ViewState private var isRenaming = false
    @ViewState private var draft = ""
    @FocusState private var isEditing: Bool

    var body: some View {
        HStack(spacing: 12) {
            SymbolBadge(symbol: profile.symbol, tint: profile.tint, isActive: isActive, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                if isRenaming {
                    nameField
                } else {
                    Text(profile.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                }
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(needsDiskAccess ? AnyShapeStyle(Self.warning) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 12)
            RulePicker(profile: profile)
            if isActive {
                Label("On", systemImage: "checkmark.circle.fill")
                    .modifier(CheckCapsule(width: 76))
                    .accessibilityLabel("\(profile.name) is on")
            } else {
                CapsuleButton(title: "Switch") { store.switchTo(profile) }
                    .frame(width: 76)
                    .accessibilityLabel("Switch to \(profile.name)")
            }
            Menu {
                Button("Rename…", action: startRenaming)
                Button("Delete", role: .destructive) { store.delete(profile) }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Palette.wash))
                    .overlay(Circle().strokeBorder(Palette.rimGradient))
                    .contentShape(Circle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More for \(profile.name)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contextMenu {
            if !isActive { Button("Switch to \(profile.name)") { store.switchTo(profile) } }
            Button("Rename…", action: startRenaming)
            Button("Delete", role: .destructive) { store.delete(profile) }
        }
    }

    private var nameField: some View {
        TextField("Name", text: $draft)
            .textFieldStyle(.plain)
            .font(.system(size: 13, weight: .medium))
            .focused($isEditing)
            .onSubmit(commitRename)
            .onExitCommand { isRenaming = false }
            .onChange(of: isEditing) { if !isEditing { commitRename() } }
            .padding(.horizontal, 9)
            .frame(maxWidth: 220, minHeight: 22)
            .background(FieldWell())
    }

    /// Orange in the window's shade, deep enough to read on the light page.
    static let warning = WindowAccent(choice: .orange).color

    private var needsDiskAccess: Bool {
        profile.isFocusRule && focus.access == .denied
    }

    private var detail: String {
        if isRenaming, store.isNameTaken(draft, by: profile) { return "There's already a profile called “\(draft.trimmingCharacters(in: .whitespaces))”" }
        if needsDiskAccess { return "Needs Full Disk Access, under Permissions, to see your Focus" }
        switch profile.rule {
        case nil: return "Switch to it here or from the menu bar"
        case .focus(nil, _): return "Switches on with any Focus"
        case .focus(_, let name): return "Switches on with the \(name) Focus"
        case .externalDisplay: return "Switches on with an external display"
        }
    }

    private func startRenaming() {
        draft = profile.name
        isRenaming = true
        DispatchQueue.main.async { isEditing = true }
    }

    private func commitRename() {
        guard isRenaming else { return }
        isRenaming = false
        if !store.isNameTaken(draft, by: profile) { store.rename(profile, to: draft) }
    }
}

/// What switches a profile on by itself: nothing, a Focus, or an external display.
private struct RulePicker: View {
    let profile: Profile
    @ObservedObject private var store = ProfileStore.shared
    @ObservedObject private var focus = FocusMonitor.shared
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.windowAccent) private var accent

    private enum Choice: Hashable {
        case byHand, anyFocus, focus(String), display
    }

    var body: some View {
        Menu {
            Picker("Switches on", selection: selection) {
                Text("By hand").tag(Choice.byHand)
                Section("When a Focus turns on") {
                    Text("Any Focus").tag(Choice.anyFocus)
                    ForEach(focusChoices, id: \.id) { mode in
                        Text(mode.name).tag(Choice.focus(mode.id))
                    }
                }
                Section {
                    Text("When an external display connects").tag(Choice.display)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            if focus.access == .denied {
                Text("Focus rules need Full Disk Access")
            }
        } label: {
            // A chip: quiet while the profile is switched by hand, and in the accent, like a
            // selected chip, while something switches it on by itself.
            let hasRule = profile.rule != nil
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(hasRule ? accent.color : Color.secondary)
                Text(title)
                    .font(.system(size: 12, weight: hasRule ? .semibold : .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(hasRule ? AnyShapeStyle(accent.color.opacity(0.7)) : AnyShapeStyle(.secondary))
            }
            .foregroundStyle(hasRule ? accent.color : Color.primary.opacity(0.78))
            .padding(.horizontal, 11)
            .frame(height: 26)
            .background {
                // As faint as a selected chip's in light mode, where the accent's text has little room above 4.5:1.
                Capsule().fill(hasRule ? AnyShapeStyle(accent.color.opacity(colorScheme == .dark ? 0.12 : 0.06))
                                       : AnyShapeStyle(Palette.wash))
                    .overlay(Capsule().strokeBorder(accent.color.opacity(hasRule ? 0.55 : 0), lineWidth: 1.2))
            }
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("What switches \(profile.name) on by itself")
        .accessibilityLabel("\(profile.name) switches on")
        .accessibilityValue(title)
    }

    private var title: String {
        switch profile.rule {
        case nil: "By hand"
        case .focus(nil, _): "Any Focus"
        case .focus(_, let name): name
        case .externalDisplay: "External display"
        }
    }

    private var symbol: String {
        switch profile.rule {
        case nil: "hand.point.up.left.fill"
        case .focus(nil, _): "moon.fill"
        case .focus(let id?, _): focus.modes.first { $0.id == id }?.symbol ?? "moon.fill"
        case .externalDisplay: "display"
        }
    }

    /// The Focuses set up on this Mac, plus the rule's own if it's gone from the list.
    private var focusChoices: [FocusMode] {
        var modes = focus.modes
        if case .focus(let id?, let name) = profile.rule, !modes.contains(where: { $0.id == id }) {
            modes.append(FocusMode(id: id, name: name, symbol: "moon.fill", tint: .indigo))
        }
        return modes
    }

    private var selection: Binding<Choice> {
        Binding {
            switch profile.rule {
            case nil: .byHand
            case .focus(nil, _): .anyFocus
            case .focus(let id?, _): .focus(id)
            case .externalDisplay: .display
            }
        } set: { choice in
            let rule: Profile.Rule? = switch choice {
            case .byHand: nil
            case .anyFocus: .focus(id: nil, name: "Any Focus")
            case .focus(let id): .focus(id: id, name: focusChoices.first { $0.id == id }?.name ?? "Focus")
            case .display: .externalDisplay
            }
            store.setRule(rule, for: profile)
        }
    }
}

/// A name and a button that saves the setup you have now under it.
private struct NewProfileRow: View {
    @ObservedObject private var store = ProfileStore.shared
    @ViewState private var name = ""

    var body: some View {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let taken = store.isNameTaken(trimmed)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                SymbolBadge(symbol: "plus", isActive: !trimmed.isEmpty && !taken, size: 28)
                TextField(store.profiles.isEmpty ? "Name it, like Work or Home" : "Another profile's name", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .onSubmit(save)
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(FieldWell())
                CapsuleButton(title: "Save Current Setup", symbol: "square.and.arrow.down", kind: .prominent, action: save)
                    .disabled(trimmed.isEmpty || taken)
            }
            if taken {
                Text("There's already a profile called “\(trimmed)”.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(ProfileRow.warning)
                    .padding(.leading, 40)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func save() {
        guard store.saveCurrent(as: name) != nil else { return }
        name = ""
    }
}
