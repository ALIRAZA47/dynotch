import SwiftUI

/// The Clipboard section: a search field, then a row for each clip, pinned first, then newest.
/// Code shows in mono, a color as its swatch, a link by its host. Copy, Pin and Remove are the row's
/// actions, shown as Settings › Appearance › Row actions says. Any note about the history being off,
/// or macOS refusing, comes before them.
struct ClipboardSection: View {
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject private var store = ClipboardStore.shared
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.notchTheme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let clips = store.clips(matching: viewModel.clipSearch)
        VStack(spacing: 8) {
            if settings.clipboardHistory || !store.clips.isEmpty {
                ClipboardSearchField(text: $viewModel.clipSearch)
            }
            if viewModel.clipSearch.isEmpty, let note, clips.isEmpty {
                ClipNote(message: note.message, buttonTitle: note.buttonTitle, isAlone: true, action: note.action)
            } else if clips.isEmpty {
                Text(viewModel.clipSearch.isEmpty ? "Nothing copied yet. What you copy shows up here." : "No clips match.")
                    .font(NotchFont.body)
                    .foregroundStyle(theme.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                if viewModel.clipSearch.isEmpty, let note {
                    ClipNote(message: note.message, buttonTitle: note.buttonTitle, isAlone: false, action: note.action)
                }
                Scroller(.vertical, fadesOverflow: true) {
                    VStack(spacing: 0) {
                        ForEach(Array(clips.enumerated()), id: \.element.id) { index, clip in
                            if index > 0 { OrbitRowDivider() }
                            ClipRow(clip: clip, now: now, forcesHover: isSnapshot && TraySnapshot.hoveredClip == index, viewModel: viewModel)
                                .transition(reduceMotion ? AnyTransition.opacity : .opacity.combined(with: .move(edge: .top)))
                        }
                    }
                    .accessibilityElement(children: .contain)
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .orbitHeader("Clipboard", subtitle: subtitle(matching: clips.count)) {
            if store.clips.contains(where: { !$0.isPinned }) {
                OrbitButton(title: "Clear", style: .ghost, help: "Clear the clipboard history, all but what's pinned") { store.clear() }
            }
        }
    }

    private var now: Date { isSnapshot ? SnapshotClock.now : .now }

    /// "38 copies · 2 pinned", "3 of 38 match", "History off".
    private func subtitle(matching count: Int) -> String {
        let total = store.clips.count
        if !viewModel.clipSearch.isEmpty { return "\(count) of \(total) match" }
        guard total > 0 else { return settings.clipboardHistory ? "Nothing yet" : "History off" }
        var parts = [total == 1 ? "1 copy" : "\(total) copies"]
        let pinned = store.clips.filter(\.isPinned).count
        if pinned > 0 { parts.append("\(pinned) pinned") }
        return parts.joined(separator: " · ")
    }

    /// What's in the way of new clips, and the button that does something about it.
    private var note: (message: String, buttonTitle: String, action: () -> Void)? {
        if !settings.clipboardHistory {
            return ("Keep the last 50 things you copy, on this Mac only.", "Turn On", { AppSettings.shared.clipboardHistory = true })
        }
        return store.access.problem.map { ($0, "Privacy & Security", ClipboardStore.openPrivacySettings) }
    }
}

/// Searches the clips, across the top of the section.
struct ClipboardSearchField: View {
    @Binding var text: String
    @Environment(\.notchTheme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot
    @FocusState private var isFocused: Bool
    @ViewState private var hovering = false

    var body: some View {
        let shape = theme.controlShape
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(isFocused ? theme.accentText : theme.secondary)
            if isSnapshot {
                Text(text.isEmpty ? "Search what you copied" : text)
                    .font(NotchFont.body)
                    .foregroundStyle(text.isEmpty ? theme.secondary : theme.primary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField("Search what you copied", text: $text, prompt: Text(""))
                    .textFieldStyle(.plain)
                    .font(NotchFont.body)
                    .fieldPlaceholder("Search what you copied", isEmpty: text.isEmpty, font: NotchFont.body, color: theme.secondary)
                    .focused($isFocused)
            }
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.secondary)
                }
                .buttonStyle(PressableButtonStyle())
                .help("Clear the search")
                .accessibilityLabel("Clear the search")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(shape.fill(theme.field))
        .overlay(shape.strokeBorder(isFocused ? theme.accent : hovering ? theme.controlHover : theme.line, lineWidth: isFocused ? 1.5 : 1))
        .contentShape(shape)
        .onHover { hovering = $0 }
        .animation(.notchHighlight, value: isFocused)
    }
}

/// Says why the list isn't filling up, with the button that fixes it. Alone, it has the section to
/// itself; above the clips, it's a card of its own.
private struct ClipNote: View {
    let message: String
    let buttonTitle: String
    let isAlone: Bool
    let action: () -> Void
    @Environment(\.notchTheme) private var theme

    var body: some View {
        if isAlone {
            VStack(spacing: 12) {
                glyph
                Text(message)
                    .font(NotchFont.body)
                    .foregroundStyle(theme.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                PillButton(title: buttonTitle, action: action)
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .contain)
        } else {
            HStack(spacing: 12) {
                glyph
                Text(message)
                    .font(NotchFont.subheadline)
                    .foregroundStyle(theme.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                PillButton(title: buttonTitle, action: action)
            }
            .padding(.horizontal, 10)
            .frame(height: NotchTheme.rowHeight)
            .background(theme.controlShape.fill(theme.raised).overlay(theme.controlShape.strokeBorder(theme.line)))
            .accessibilityElement(children: .contain)
        }
    }

    private var glyph: some View {
        Image(systemName: "doc.on.clipboard")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(theme.secondary)
            .frame(width: 30, height: 30)
            .background(theme.controlShape.fill(theme.hover))
            .accessibilityHidden(true)
    }
}

/// A clip as a row: its glyph, or a swatch for a color, the clip in a line, what it is and when, and
/// Pinned or how long ago on the right until its actions show. A click copies it back and closes
/// the notch.
private struct ClipRow: View {
    let clip: ClipboardStore.Clip
    let now: Date
    /// Drawn as under the pointer, for snapshots.
    var forcesHover = false
    let viewModel: NotchViewModel
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.notchTheme) private var theme
    @Environment(\.rowActionHost) private var host
    @ViewState private var isPointedAt = false

    private var hovering: Bool { isPointedAt || forcesHover }

    private var actions: [RowAction] {
        [
            RowAction(title: clip.isPinned ? "Unpin" : "Pin") { ClipboardStore.shared.togglePin(clip) },
            RowAction(title: "Remove") { ClipboardStore.shared.remove(clip) },
            RowAction(title: "Copy", role: .primary, perform: copy),
        ]
    }

    var body: some View {
        HStack(spacing: 12) {
            glyph
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(isMono ? .system(size: 12.5, weight: .semibold, design: .monospaced) : NotchFont.headline)
                    .foregroundStyle(theme.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(subtitle)
                    .font(NotchFont.subheadline)
                    .foregroundStyle(theme.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.horizontal, 10)
        .frame(height: NotchTheme.rowHeight)
        .background {
            if hovering {
                theme.controlShape.fill(theme.raised)
                    .overlay(theme.controlShape.strokeBorder(theme.line))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: copy)
        .onHover { inside in
            isPointedAt = inside
            if inside { host?.setHot(.init(id: clip.id.uuidString, title: title, actions: actions)) }
        }
        .animation(.notchHighlight, value: isPointedAt)
        .contextMenu { ClipMenu(clip: clip, copy: copy, close: viewModel.close) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(clip.spokenTitle)
        .accessibilityValue(clip.isPinned ? "Pinned" : "")
        .accessibilityHint("Copies it and closes the notch")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, copy)
        .accessibilityAction(named: clip.isPinned ? "Unpin" : "Pin") { ClipboardStore.shared.togglePin(clip) }
        .accessibilityAction(named: "Remove") { ClipboardStore.shared.remove(clip) }
    }

    private var isMono: Bool {
        switch clip.kind {
        case .code, .color: true
        case .text, .link: false
        }
    }

    /// The link's host, or the clip's first line.
    private var title: String {
        if case .link(let url) = clip.kind, let host = url.host { return host }
        return clip.title
    }

    /// "Code · 2 min ago", "/launch/checklist · 3 min ago", "3 lines · 1 h ago".
    private var subtitle: String {
        let when = ClipAge.long(from: clip.copiedAt, to: now)
        let what: String
        switch clip.kind {
        case .code: what = "Code"
        case .color: what = "Color"
        case .link(let url):
            let rest = url.path + (url.query.map { "?\($0)" } ?? "")
            what = rest.isEmpty || rest == "/" ? "Link" : rest
        case .text:
            let lines = clip.preview.split(separator: "\n", omittingEmptySubsequences: true).count
            what = lines > 1 ? "\(lines) lines" : "Text"
        }
        return "\(what) · \(when)"
    }

    @ViewBuilder
    private var glyph: some View {
        let shape = theme.controlShape
        switch clip.kind {
        case .color(let red, let green, let blue, let opacity):
            shape.fill(Color(.sRGB, red: red, green: green, blue: blue, opacity: opacity))
                .overlay(shape.strokeBorder(theme.line))
                .frame(width: 30, height: 30)
                .accessibilityHidden(true)
        default:
            Image(systemName: symbol)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(theme.secondary)
                .frame(width: 30, height: 30)
                .background(shape.fill(theme.hover))
                .accessibilityHidden(true)
        }
    }

    private var symbol: String {
        switch clip.kind {
        case .code: "terminal"
        case .link: "link"
        case .text, .color: "text.alignleft"
        }
    }

    @ViewBuilder
    private var trailing: some View {
        let mode = settings.rowActionMode
        let shown: [RowAction] = switch mode {
        case .always: actions
        case .hover: hovering ? actions : []
        case .primary: hovering ? actions : RowAction.main(of: actions).map { [$0] } ?? []
        case .bar, .band, .menu: []
        }
        HStack(spacing: 6) {
            if shown.isEmpty || mode == .primary && !hovering {
                status
            }
            ForEach(shown) { action in
                RowActionButton(action: action)
            }
            if mode == .menu {
                MenuButton(help: "Actions") { hot in
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(hot ? theme.primary : theme.secondary)
                        .frame(width: 28, height: 26)
                        .background(theme.controlShape.fill(hot ? theme.controlHover : theme.hover))
                } items: {
                    actions.map { action in MenuEntry.item(action.title, action: action.perform) }
                }
            }
        }
        .fixedSize()
    }

    @ViewBuilder
    private var status: some View {
        if clip.isPinned {
            HStack(spacing: 5) {
                Image(systemName: "pin.fill").font(.system(size: 9, weight: .bold))
                Text("Pinned")
            }
            .font(.system(size: 12))
            .foregroundStyle(theme.accentText)
            .help("Pinned: stays when the history is cleared")
        } else {
            Text(ClipAge.short(from: clip.copiedAt, to: now))
                .font(NotchFont.time(12, .medium))
                .foregroundStyle(theme.secondary)
        }
    }

    private func copy() {
        ClipboardStore.shared.copy(clip)
        viewModel.close()
    }
}

/// How long ago something was copied.
enum ClipAge {
    /// "now", "2 min", "1 h", "3 d".
    static func short(from date: Date, to now: Date) -> String {
        let minutes = Int(max(0, now.timeIntervalSince(date)) / 60)
        if minutes < 1 { return "now" }
        if minutes < 60 { return "\(minutes) min" }
        if minutes < 24 * 60 { return "\(minutes / 60) h" }
        return "\(minutes / (24 * 60)) d"
    }

    /// "just now", "2 min ago".
    static func long(from date: Date, to now: Date) -> String {
        let short = short(from: date, to: now)
        return short == "now" ? "just now" : "\(short) ago"
    }
}

private struct ClipMenu: View {
    let clip: ClipboardStore.Clip
    let copy: () -> Void
    let close: () -> Void

    var body: some View {
        Button("Copy", action: copy)
        Button(clip.isPinned ? "Unpin" : "Pin") { ClipboardStore.shared.togglePin(clip) }
        // Only ever http or https: anything else stays plain text.
        if case .link(let url) = clip.kind {
            Button("Open Link") {
                NSWorkspace.shared.open(url)
                close()
            }
        }
        if OnDeviceText.isAvailable {
            Divider()
            TranslateMenu(text: { clip.text }, after: close)
            if clip.text.utf16.count >= TextActions.shortestSummary {
                Button("Summarize") {
                    close()
                    Task { await TextActions.summarize(clip.text) }
                }
            }
        }
        Divider()
        Button("Remove") { ClipboardStore.shared.remove(clip) }
    }
}
