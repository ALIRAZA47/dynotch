import SwiftUI

/// Notes: the notes listed on the left, newest first, and the one picked open on the right, its
/// first line as its title. Saved as Markdown files as you type.
struct NotesSection: View {
    @ObservedObject private var store = NotesStore.shared
    @ObservedObject private var settings = AppSettings.shared
    @ViewState private var editor = NoteEditorHandle()
    @Environment(\.notchTheme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            NotesList()
                .frame(width: settings.openWidth < 700 ? 168 : 190)
            VStack(alignment: .leading, spacing: 10) {
                if let left = store.leftBehind {
                    LeftBehindStrip(left: left)
                }
                if store.saveFailed {
                    SaveFailedStrip()
                }
                NoteBody(editor: editor, style: .page)
            }
            .padding(EdgeInsets(top: 14, leading: 16, bottom: 12, trailing: 16))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(CardSurface())
        }
        .orbitHeader("Notes", subtitle: subtitle) {
            NotesActions(editor: editor, inBand: true)
        }
    }

    /// "4 notes · iCloud Drive › Dynotch Notes"
    private var subtitle: String {
        let count = store.notes.filter { !$0.isBlank }.count
        return (count == 1 ? "1 note" : "\(count) notes") + " · " + Self.place(of: store)
    }

    static func place(of store: NotesStore) -> String {
        if store.isUsingDefaultFolder { return "Dynotch" }
        let drive = "/Library/Mobile Documents/com~apple~CloudDocs"
        if let range = store.folder.path.range(of: drive) {
            let rest = store.folder.path[range.upperBound...].split(separator: "/").joined(separator: " › ")
            return rest.isEmpty ? "iCloud Drive" : "iCloud Drive › " + rest
        }
        return store.folder.lastPathComponent
    }
}

/// The notes, newest first: each its title and how far its checklist has got, with the one open
/// washed in the accent.
private struct NotesList: View {
    @ObservedObject private var store = NotesStore.shared

    var body: some View {
        Scroller(.vertical, fadesOverflow: true) {
            VStack(spacing: 2) {
                ForEach(store.notes.reversed()) { note in
                    NoteListRow(note: note, isOpen: note.id == store.currentID) { store.select(note.id) }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Notes")
    }
}

private struct NoteListRow: View {
    let note: NotesStore.Note
    let isOpen: Bool
    let action: () -> Void
    @Environment(\.notchTheme) private var theme
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 1) {
                Text(note.title.isEmpty ? "New Note" : note.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.primary)
                    .lineLimit(1)
                // On the accent's wash the secondary grey falls short of 4.5:1 in light.
                Text(Self.meta(of: note))
                    .font(.system(size: 12))
                    .foregroundStyle(isOpen && !theme.isDark ? theme.primary : theme.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if isOpen {
                    theme.controlShape.fill(theme.accentSoft)
                } else if hovering {
                    theme.controlShape.fill(theme.hover)
                }
            }
            .contentShape(theme.controlShape)
        }
        .buttonStyle(PressableButtonStyle(scale: 0.98))
        .onHover { hovering = $0 }
        .animation(.notchHighlight, value: hovering)
        .help(note.title)
        .accessibilityLabel(note.title.isEmpty ? "New Note" : note.title)
        .accessibilityValue(Self.meta(of: note))
        .accessibilityAddTraits(isOpen ? .isSelected : [])
    }

    /// "3 of 5 done · Today", "Mon", "18 Nov".
    static func meta(of note: NotesStore.Note) -> String {
        var total = 0, done = 0
        for line in note.text.split(whereSeparator: \.isNewline) {
            if case .checklist(let checked) = NoteLine(line).kind {
                total += 1
                if checked { done += 1 }
            }
        }
        let day = when(note.created)
        return total > 0 ? "\(done) of \(total) done · \(day)" : day
    }

    private static func when(_ date: Date, now: Date = .now) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day,
           (0..<7).contains(days) {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}

/// The notes left in the last folder, with a button to bring them here.
private struct LeftBehindStrip: View {
    let left: NotesStore.LeftBehind
    @ObservedObject private var store = NotesStore.shared
    @Environment(\.notchTheme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.secondary)
            Text((left.count == 1 ? "1 note stayed behind" : "\(left.count) notes stayed behind")
                 + " in \(left.folder.lastPathComponent)")
                .font(NotchFont.subheadline)
                .foregroundStyle(theme.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(left.folder.path)
            OrbitButton(title: left.count == 1 ? "Bring It Here" : "Bring Them Here") { store.bringLeftBehind() }
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(height: 34)
        .background(theme.controlShape.fill(theme.hover))
    }
}

/// The last save failed, say because the folder went away.
private struct SaveFailedStrip: View {
    @Environment(\.notchTheme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(theme.alert)
            Text("Couldn't save. Check the notes folder in Settings → Nook & Widgets.")
                .font(NotchFont.subheadline)
                .foregroundStyle(theme.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(theme.controlShape.fill(theme.alert.opacity(theme.isDark ? 0.14 : 0.1)))
        .accessibilityElement(children: .combine)
    }
}
