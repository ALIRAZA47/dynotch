import SwiftUI

/// Searches the shelf, from the right of the Tray's toolbar. With the history off and nothing pinned
/// there's nothing to search.
struct ClipboardSearchField: View {
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject private var store = ClipboardStore.shared
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        if settings.clipboardHistory || !store.clips.isEmpty {
            CardField(placeholder: "Search clips", text: $viewModel.clipSearch, symbol: "magnifyingglass") {}
                .frame(width: 170)
        }
    }
}

/// The Clipboard side's shelf: the same pane of glass as the files, with a card for each clip, pinned
/// first, then newest. Any note about the history being off, or macOS refusing, comes before them.
struct ClipboardShelf: View {
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject private var store = ClipboardStore.shared
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.notchTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let clips = store.clips(matching: viewModel.clipSearch)
            // More cards than fit scroll sideways, as far as the shelf's rim, as the files do.
            ViewThatFits(in: .horizontal) {
                strip(clips, height: proxy.size.height)
                    .padding(.horizontal, theme.controlRadius)
                Scroller(.horizontal) {
                    strip(clips, height: proxy.size.height)
                        .padding(.horizontal, theme.controlRadius)
                }
            }
        }
        .padding(.vertical, theme.controlRadius)
        .clipShape(RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous).inset(by: 1))
        .background(CardSurface())
    }

    private func strip(_ clips: [ClipboardStore.Clip], height: CGFloat) -> some View {
        HStack(spacing: 6) {
            if viewModel.clipSearch.isEmpty, let note {
                ClipNote(message: note.message, buttonTitle: note.buttonTitle, isAlone: clips.isEmpty, action: note.action)
            } else if clips.isEmpty {
                Text(viewModel.clipSearch.isEmpty ? "Nothing copied yet. What you copy shows up here." : "No clips match.")
                    .font(NotchFont.footnote)
                    .foregroundStyle(theme.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            ForEach(clips) { clip in
                ClipCard(clip: clip, height: height, viewModel: viewModel)
                    .transition(reduceMotion ? AnyTransition.opacity : .scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .accessibilityElement(children: .contain)
        .frame(maxHeight: .infinity)
    }

    /// What's in the way of new clips, and the button that does something about it.
    private var note: (message: String, buttonTitle: String, action: () -> Void)? {
        if !settings.clipboardHistory {
            return ("Keep the last 50 things you copy, on this Mac only.", "Turn On", { AppSettings.shared.clipboardHistory = true })
        }
        return store.access.problem.map { ($0, "Privacy & Security", ClipboardStore.openPrivacySettings) }
    }
}

/// Says why the shelf isn't filling up. Alone, it has the shelf to itself; beside the clips, it's a
/// column of its own.
private struct ClipNote: View {
    let message: String
    let buttonTitle: String
    let isAlone: Bool
    let action: () -> Void
    @Environment(\.notchTheme) private var theme

    var body: some View {
        VStack(spacing: 6) {
            Text(message)
                .font(NotchFont.footnote)
                .foregroundStyle(theme.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            PillButton(title: buttonTitle, action: action)
        }
        .padding(.horizontal, 10)
        .frame(width: isAlone ? nil : 170)
        .frame(maxWidth: isAlone ? .infinity : nil, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

/// A clip on the shelf, as tall as a file's tile: a few lines of it, a swatch for a hex color, the
/// host for a link. A click copies it back and closes the notch.
private struct ClipCard: View {
    let clip: ClipboardStore.Clip
    /// The shelf's, which is how many lines there's room for.
    let height: CGFloat
    let viewModel: NotchViewModel
    @Environment(\.notchTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState private var hovering = false

    private static let width: CGFloat = 150
    private static let padding: CGFloat = 8
    /// A pinned card's text starts under the pin, which sits where it does on a file's tile.
    private static let pinRow: CGFloat = 12
    private static let lineHeight: CGFloat = 14.5

    private var topPadding: CGFloat { Self.padding + (clip.isPinned ? Self.pinRow : 0) }
    private var lines: Int { max(1, Int((height - topPadding - Self.padding) / Self.lineHeight)) }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: theme.controlRadius, style: .continuous)
        Button(action: copy) {
            face
                .padding(EdgeInsets(top: topPadding, leading: 10, bottom: Self.padding, trailing: 10))
                .frame(width: Self.width, alignment: .leading)
                .frame(maxHeight: .infinity, alignment: .topLeading)
                .background(GlassSurface(depth: .pane, shape: shape, isLit: hovering))
                .contentShape(shape)
        }
        .buttonStyle(PressableButtonStyle(scale: 0.97))
        .accessibilityLabel(clip.spokenTitle)
        .accessibilityValue(clip.isPinned ? "Pinned" : "")
        .accessibilityHint("Copies it and closes the notch")
        .accessibilityAction(named: clip.isPinned ? "Unpin" : "Pin") { ClipboardStore.shared.togglePin(clip) }
        .accessibilityAction(named: "Remove") { ClipboardStore.shared.remove(clip) }
        .overlay(alignment: .topLeading) {
            if clip.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(theme.accent)
                    .padding(7)
                    .help("Pinned: stays when the history is cleared")
                    // The card says so itself.
                    .accessibilityHidden(true)
            }
        }
        .overlay(alignment: .topTrailing) {
            if hovering {
                Button { ClipboardStore.shared.remove(clip) } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Color.black, Color.white.opacity(0.85))
                }
                .buttonStyle(PressableButtonStyle())
                .help("Remove from the clipboard history")
                .accessibilityLabel("Remove")
                .transition(reduceMotion ? AnyTransition.opacity : .scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .onHover { hovering = $0 }
        .animation(.notchHighlight, value: hovering)
        .contextMenu { ClipMenu(clip: clip, copy: copy, close: viewModel.close) }
    }

    @ViewBuilder
    private var face: some View {
        switch clip.kind {
        case .text, .code:
            Text(clip.preview)
                .font(clip.kind == .code ? NotchFont.mono : NotchFont.body)
                .foregroundStyle(theme.primary)
                .lineLimit(lines)
        case .color(let red, let green, let blue, let opacity):
            let swatch = RoundedRectangle(cornerRadius: max(theme.controlRadius - 3, 3), style: .continuous)
            VStack(alignment: .leading, spacing: 6) {
                swatch.fill(Color(.sRGB, red: red, green: green, blue: blue, opacity: opacity))
                    .overlay(swatch.strokeBorder(.white.opacity(0.18)))
                Text(clip.title)
                    .font(NotchFont.mono)
                    .foregroundStyle(theme.primary)
                    .lineLimit(1)
            }
        case .link(let url):
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Image(systemName: "link")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(theme.accent)
                    Text(url.host ?? clip.title)
                        .font(NotchFont.bodyStrong)
                        .foregroundStyle(theme.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(clip.preview)
                    .font(NotchFont.caption)
                    .foregroundStyle(theme.secondary)
                    .lineLimit(max(lines - 1, 1))
            }
        }
    }

    private func copy() {
        ClipboardStore.shared.copy(clip)
        viewModel.close()
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
