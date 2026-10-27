import AppKit
import SwiftUI

/// Notes that are always one hover away: several of them, with Markdown checklists, kept as files
/// in a folder that can sync. Saved as you type.
struct NotesWidget: View {
    @ObservedObject private var store = NotesStore.shared
    @ViewState private var editor = NoteEditorHandle()
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        // Beside the player there's no room for "1/2" as well as the title.
        GeometryReader { proxy in
            card(isNarrow: proxy.size.width < 170)
        }
    }

    private func card(isNarrow: Bool) -> some View {
        WidgetCard(title: "Notes", symbol: "note.text") {
            HStack(spacing: 0) {
                if store.saveFailed {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.orange)
                        .help("Couldn't save. Check the notes folder in Settings → Nook & Widgets.")
                }
                smallButton("checklist", help: "Checklist") { editor.toggleChecklist() }
                notesMenu(showsCount: !isNarrow)
                smallButton("square.and.pencil", help: "New note") { store.newNote() }
            }
        } content: {
            ZStack(alignment: .topLeading) {
                if isSnapshot {
                    NotePreview(text: store.current?.text ?? "")
                } else if let note = store.current {
                    NoteEditor(noteID: note.id, text: note.text, handle: editor) { store.update(note.id, text: $0) }
                }
                if store.current?.isBlank ?? true {
                    Text("Jot something down…")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.notchTertiary)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    /// Which note this is, and a menu to switch notes or act on this one.
    private func notesMenu(showsCount: Bool) -> some View {
        let index = store.notes.firstIndex { $0.id == store.currentID }
        return MenuButton(help: "Notes") {
            HStack(spacing: 2) {
                if showsCount, store.notes.count > 1, let index {
                    Text("\(index + 1)/\(store.notes.count)")
                        .font(.system(size: 9.5, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .fixedSize()
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .padding(.horizontal, 4)
            .frame(height: 14)
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
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(current?.text ?? "", forType: .string)
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

    private func smallButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9.5, weight: .semibold))
                .frame(width: 18, height: 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .help(help)
    }
}

/// The note drawn in SwiftUI for snapshots, which can't draw the AppKit editor. Matches its styling.
private struct NotePreview: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, raw in
                line(NoteLine(raw))
            }
        }
        .font(.system(size: 11.5))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
    }

    @ViewBuilder
    private func line(_ line: NoteLine) -> some View {
        switch line.kind {
        case .checklist(let checked):
            HStack(spacing: 6) {
                Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(checked ? Color.yellow : Color.white.opacity(0.5))
                Text(line.content)
                    .strikethrough(checked, color: Color.notchTertiary)
                    .foregroundStyle(checked ? Color.notchTertiary : Color.white)
            }
            .padding(.leading, CGFloat(line.indent.count) * 6)
        case .heading:
            Text(line.content)
                .font(.system(size: 12.5, weight: .bold))
        case .bullet:
            Text("\(Text(line.marker).foregroundStyle(Color.notchTertiary))\(line.content)")
        case .text:
            Text(line.content.isEmpty ? " " : line.content)
        }
    }
}

/// A line in a pop-up menu.
enum MenuEntry {
    case item(String, isChecked: Bool = false, isEnabled: Bool = true, action: () -> Void)
    case separator
}

/// A header button that pops up an AppKit menu at the pointer, which behaves the same in the
/// notch's non-activating panel as a context menu does.
struct MenuButton<Label: View>: View {
    var help: String
    @ViewBuilder let label: Label
    let items: () -> [MenuEntry]

    var body: some View {
        Button(action: show) {
            label.contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .help(help)
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
