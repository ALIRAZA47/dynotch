import AppKit
import SwiftUI

/// Notes that are always one hover away: several of them, with Markdown checklists, kept as files
/// in a folder that can sync. Saved as you type. This is the card for the Widgets stack; the Notes
/// section shows the list of them beside the note.
struct NotesWidget: View {
    @ViewState private var editor = NoteEditorHandle()

    var body: some View {
        // In a narrow card there's no room for "1/2" as well as the title.
        GeometryReader { proxy in
            WidgetCard(title: "Notes", symbol: "note.text") {
                NotesActions(editor: editor, showsCount: proxy.size.width >= 170)
            } content: {
                NoteBody(editor: editor)
            }
        }
    }
}

/// The note being edited, or a hint while it's empty.
struct NoteBody: View {
    let editor: NoteEditorHandle
    var style: NoteStyle = .card
    @ObservedObject private var store = NotesStore.shared
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.notchTheme) private var theme

    var body: some View {
        ZStack(alignment: .topLeading) {
            if isSnapshot {
                // The editor scrolls, so a long note mustn't make the card taller.
                Color.clear
                    .overlay(alignment: .topLeading) { NotePreview(text: store.current?.text ?? "", style: style) }
                    .clipped()
            } else if let note = store.current {
                NoteEditor(noteID: note.id, text: note.text, handle: editor, style: style) { store.update(note.id, text: $0) }
            }
            if store.current?.isBlank ?? true {
                Text("Jot something down…")
                    .font(.system(size: style.titleSize ?? style.size, weight: style.titleSize == nil ? .regular : .semibold))
                    .foregroundStyle(theme.tertiary)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The buttons for the note: a checklist, the notes menu and a new note. Small symbols in a card's
/// title row; Orbit buttons in the band beside the camera.
struct NotesActions: View {
    let editor: NoteEditorHandle
    var showsCount = true
    /// For the band beside the camera, where New note is spelled out.
    var inBand = false
    @ObservedObject private var store = NotesStore.shared
    @Environment(\.notchTheme) private var theme

    var body: some View {
        HStack(spacing: inBand ? 6 : 0) {
            // Notes says so in a strip over the note; the card has only room for the sign.
            if store.saveFailed, !inBand {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: inBand ? 12 : 9.5))
                    .foregroundStyle(theme.alert)
                    .padding(.trailing, 2)
                    .help("Couldn't save. Check the notes folder in Settings → Nook & Widgets.")
                    .accessibilityLabel("Couldn't save")
            }
            if inBand {
                OrbitButton(symbol: "checklist", style: .ghost, help: "Checklist") { editor.toggleChecklist() }
                notesMenu(showsCount: false)
                OrbitButton(title: "New note", help: "New note") { store.newNote() }
            } else {
                CardButton(symbol: "checklist", help: "Checklist") { editor.toggleChecklist() }
                notesMenu(showsCount: showsCount)
                CardButton(symbol: "square.and.pencil", help: "New note") { store.newNote() }
            }
        }
    }

    /// Which note this is, and a menu to switch notes or act on this one.
    private func notesMenu(showsCount: Bool) -> some View {
        let index = store.notes.firstIndex { $0.id == store.currentID }
        let count = showsCount && store.notes.count > 1 ? index.map { "\($0 + 1)/\(store.notes.count)" } : nil
        return MenuButton(help: "Notes") { hovering in
            if inBand {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(hovering ? theme.primary : theme.secondary)
                    .frame(width: NotchTheme.headerControlHeight, height: NotchTheme.headerControlHeight)
                    .background { if hovering { theme.controlShape.fill(theme.controlHover) } }
                    .animation(.notchHighlight, value: hovering)
            } else {
                CardButtonLabel(symbol: "chevron.down", text: count, hovering: hovering)
            }
        } items: {
            menuItems
        }
    }

    private var menuItems: [MenuEntry] {
        let current = store.current
        var items = store.notes.map { note in
            MenuEntry.item(note.title.isEmpty ? "New Note" : note.title, isChecked: note.id == current?.id) {
                store.select(note.id)
            }
        }
        items.append(.separator)
        items.append(.item("New Note") { store.newNote() })
        items.append(.item("Copy Note", isEnabled: !(current?.isBlank ?? true)) {
            NSPasteboard.dynotch.clearContents()
            NSPasteboard.dynotch.setString(current?.text ?? "", forType: .string)
        })
        items.append(.item("Show in Finder") {
            if let current, current.isOnDisk {
                FileActions.reveal([current.url])
            } else {
                NSWorkspace.shared.open(store.folder)
            }
        })
        items.append(.separator)
        items.append(.item("Delete Note", isEnabled: current != nil && !(current?.isBlank == true && store.notes.count == 1)) {
            if let current { store.delete(current.id) }
        })
        return items
    }
}

/// The note drawn in SwiftUI for snapshots, which can't draw the AppKit editor. Matches its styling.
private struct NotePreview: View {
    let text: String
    var style: NoteStyle = .card
    @Environment(\.notchTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: style.lineGap) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { index, raw in
                line(NoteLine(raw), isFirst: index == 0)
            }
        }
        .font(.system(size: style.size))
        .foregroundStyle(theme.primary)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
    }

    @ViewBuilder
    private func line(_ line: NoteLine, isFirst: Bool) -> some View {
        switch line.kind {
        case .checklist(let checked):
            HStack(spacing: 7) {
                box(checked: checked)
                Text(line.content)
                    .strikethrough(checked, color: theme.secondary)
                    .foregroundStyle(checked ? theme.secondary : theme.primary)
            }
            .padding(.leading, CGFloat(line.indent.count) * 6)
        case .heading:
            Text(line.content)
                .font(.system(size: isFirst ? style.titleSize ?? style.size + 1 : style.size + 1,
                              weight: isFirst && style.titleSize != nil ? .semibold : .bold))
        case .bullet:
            Text("\(Text(line.marker).foregroundStyle(theme.tertiary))\(line.content)")
        case .text:
            if isFirst, let titleSize = style.titleSize {
                Text(line.content.isEmpty ? " " : line.content)
                    .font(.system(size: titleSize, weight: .semibold))
            } else {
                Text(line.content.isEmpty ? " " : line.content)
            }
        }
    }

    private func box(checked: Bool) -> some View {
        let radius = min(theme.radius * 0.8, style.box / 2 - 2)
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return ZStack {
            if checked {
                shape.fill(theme.accent)
                Image(systemName: "checkmark")
                    .font(.system(size: style.box * 0.62, weight: .bold))
                    .foregroundStyle(theme.onAccent)
            } else {
                shape.strokeBorder(theme.secondary, lineWidth: 1.5)
            }
        }
        .frame(width: style.box, height: style.box)
    }
}

/// A line in a pop-up menu.
enum MenuEntry {
    case item(String, isChecked: Bool = false, isEnabled: Bool = true, action: () -> Void)
    case separator
}

/// A header button that pops up an AppKit menu at the pointer, which behaves the same in the
/// notch's non-activating panel as a context menu does. Its label knows when the pointer is over it.
struct MenuButton<Label: View>: View {
    var help: String
    @ViewBuilder let label: (_ hovering: Bool) -> Label
    let items: () -> [MenuEntry]
    @ViewState private var hovering = false

    var body: some View {
        Button(action: show) {
            label(hovering).contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }

    private func show() {
        guard let event = NSApp.currentEvent, let view = event.window?.contentView else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for entry in items() {
            switch entry {
            case .item(let title, let isChecked, let isEnabled, let action):
                let item = ClosureMenuItem(title: title, action: action)
                item.state = isChecked ? .on : .off
                item.isEnabled = isEnabled
                menu.addItem(item)
            case .separator:
                menu.addItem(.separator())
            }
        }
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }
}

/// A menu item that runs a closure.
private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, action handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) {
        fatalError("Not used")
    }

    @objc private func run() {
        handler()
    }
}
