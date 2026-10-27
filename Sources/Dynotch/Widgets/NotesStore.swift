import AppKit
import Combine
import CoreServices

/// Notes as Markdown files in a folder: Dynotch's own, or one the user picks. A folder in iCloud
/// Drive syncs them between Macs. Edits are saved as you type, and changes made on disk, by
/// another app or another Mac, show up as they land.
@MainActor
final class NotesStore: ObservableObject {
    static let shared = NotesStore()

    struct Note: Identifiable, Equatable {
        let id: UUID
        var url: URL
        var text: String
        /// The file's contents when last read or written, to tell edits here from changes made elsewhere.
        var savedText: String
        /// New notes stay in memory until they have something in them.
        var isOnDisk: Bool
        var created: Date

        /// The first line, without its Markdown marker.
        var title: String { NoteLine.title(of: text) }
        var isBlank: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    @Published private(set) var notes: [Note] = []
    @Published private(set) var currentID: Note.ID?
    @Published private(set) var folder: URL
    /// The last save failed, say because the folder went away.
    @Published private(set) var saveFailed = false

    /// ~/Library/Application Support/Dynotch/Notes
    let defaultFolder: URL

    private var stream: FSEventStreamRef?
    private var saveTasks: [Note.ID: Task<Void, Never>] = [:]
    private var reloadTask: Task<Void, Never>?
    private var terminationObserver: NSObjectProtocol?
    /// The chosen folder was gone at launch, so Dynotch's own is in use.
    private let folderWasMissing: Bool

    private static let currentKey = "notes.current"

    private init() {
        defaultFolder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dynotch/Notes", isDirectory: true)
        // Anything can write a path into the defaults; only a folder that's there is used, and never
        // created, written to or watched on the strength of the setting alone.
        let path = AppSettings.shared.notesFolderPath
        var isDirectory: ObjCBool = false
        if !path.isEmpty, FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
            folder = URL(fileURLWithPath: path, isDirectory: true)
            folderWasMissing = false
        } else {
            folder = defaultFolder
            folderWasMissing = !path.isEmpty
            if folderWasMissing { AppSettings.shared.notesFolderPath = "" }
        }
    }

    var current: Note? { notes.first { $0.id == currentID } }

    var isUsingDefaultFolder: Bool { folder.standardizedFileURL == defaultFolder.standardizedFileURL }

    func start() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        migrateScratchpad()
        reload()
        watch()
        if folderWasMissing {
            LiveActivityCenter.shared.post(LiveNotice(key: "notes", symbol: "note.text", tint: .yellow, text: "Notes",
                                                      detail: "The notes folder is gone; using Dynotch's own"), for: 5)
        }
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                                                     object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { NotesStore.shared.saveAll() }
        }
    }

    // MARK: Editing

    func update(_ id: Note.ID, text: String) {
        guard let index = notes.firstIndex(where: { $0.id == id }), notes[index].text != text else { return }
        notes[index].text = text
        saveTasks[id]?.cancel()
        saveTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.6))
            guard !Task.isCancelled else { return }
            self?.save(id)
        }
    }

    func select(_ id: Note.ID) {
        guard id != currentID, notes.contains(where: { $0.id == id }) else { return }
        let previous = currentID
        setCurrent(id)
        if let previous { discardIfBlank(previous) }
    }

    /// Starts a note, or goes back to the blank one already waiting.
    func newNote() {
        if let blank = notes.first(where: \.isBlank) {
            select(blank.id)
            return
        }
        let note = Note(id: UUID(), url: folder.appendingPathComponent("Untitled.md"), text: "", savedText: "",
                        isOnDisk: false, created: .now)
        notes.append(note)
        select(note.id)
    }

    /// Moves the note's file to the Trash.
    func delete(_ id: Note.ID) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        saveTasks[id]?.cancel()
        let note = notes.remove(at: index)
        if note.isOnDisk { try? FileManager.default.trashItem(at: note.url, resultingItemURL: nil) }
        if notes.isEmpty {
            newNote()
        } else if currentID == id {
            setCurrent(notes[min(index, notes.count - 1)].id)
        }
    }

    // MARK: Folder

    /// Keeps notes in `newFolder`, or in Dynotch's own folder when it's nil. Notes in Dynotch's own
    /// folder move along; a folder the user picked is left as it is.
    func useFolder(_ newFolder: URL?) {
        let target = (newFolder ?? defaultFolder).standardizedFileURL
        guard target != folder.standardizedFileURL else { return }
        saveAll()
        try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        if isUsingDefaultFolder {
            for note in notes where note.isOnDisk {
                let destination = FileActions.uniqueURL(for: target.appendingPathComponent(note.url.lastPathComponent))
                try? FileManager.default.moveItem(at: note.url, to: destination)
            }
        }
        AppSettings.shared.notesFolderPath = newFolder == nil ? "" : target.path
        folder = target
        notes = []
        reload()
        watch()
    }

    /// iCloud Drive's "Dynotch Notes" folder, if iCloud Drive is on.
    var iCloudFolder: URL? {
        let drive = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        guard FileManager.default.fileExists(atPath: drive.path) else { return nil }
        return drive.appendingPathComponent("Dynotch Notes", isDirectory: true)
    }

    var isInICloud: Bool {
        folder.path.contains("/Library/Mobile Documents/")
    }

    // MARK: Saving

    func saveAll() {
        for (id, task) in saveTasks {
            task.cancel()
            save(id)
        }
        saveTasks.removeAll()
    }

    private func save(_ id: Note.ID) {
        saveTasks[id] = nil
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        let note = notes[index]
        guard note.isOnDisk || !note.isBlank, note.text != note.savedText || !note.isOnDisk else { return }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var url = note.url
            // Files are named after the note's first line, and follow it when it changes.
            let name = NoteLine.fileName(for: note.text)
            if !note.isOnDisk || (!note.isBlank && !Self.isNamed(url, after: name)) {
                let target = FileActions.uniqueURL(for: folder.appendingPathComponent(name + ".md"))
                if note.isOnDisk { try FileManager.default.moveItem(at: url, to: target) }
                url = target
            }
            try note.text.write(to: url, atomically: true, encoding: .utf8)
            notes[index].url = url
            notes[index].savedText = note.text
            notes[index].isOnDisk = true
            saveFailed = false
            if id == currentID { UserDefaults.dynotch.set(url.lastPathComponent, forKey: Self.currentKey) }
        } catch {
            saveFailed = true
        }
    }

    /// "Groceries.md", or "Groceries 2.md" when another note had the name first.
    private static func isNamed(_ url: URL, after name: String) -> Bool {
        let base = url.deletingPathExtension().lastPathComponent
        guard base != name else { return true }
        return base.hasPrefix(name + " ") && Int(base.dropFirst(name.count + 1)) != nil
    }

    private func setCurrent(_ id: Note.ID?) {
        currentID = id
        if let note = current, note.isOnDisk {
            UserDefaults.dynotch.set(note.url.lastPathComponent, forKey: Self.currentKey)
        }
    }

    /// An empty note goes away once you leave it, file and all.
    private func discardIfBlank(_ id: Note.ID) {
        guard let index = notes.firstIndex(where: { $0.id == id }), notes[index].isBlank, notes.count > 1 else { return }
        saveTasks[id]?.cancel()
        let note = notes.remove(at: index)
        guard note.isOnDisk else { return }
        let onDisk = (try? String(contentsOf: note.url, encoding: .utf8)) ?? ""
        if onDisk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try? FileManager.default.removeItem(at: note.url)
        }
    }

    // MARK: Loading

    /// Reads every Markdown file in the folder. Notes edited here keep their edits; others take what's on disk.
    private func reload() {
        let keys: [URLResourceKey] = [.creationDateKey, .isRegularFileKey]
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                   options: [.skipsHiddenFiles])) ?? [])
            .filter { ["md", "markdown"].contains($0.pathExtension.lowercased()) }
        let paths = Set(files.map(\.standardizedFileURL.path))
        let known = Dictionary(notes.map { ($0.url.standardizedFileURL.path, $0) }, uniquingKeysWith: { first, _ in first })
        var gone = notes.filter { $0.isOnDisk && !paths.contains($0.url.standardizedFileURL.path) }
        var loaded: [Note] = []
        for url in files {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            if var note = known[url.standardizedFileURL.path] {
                if text != note.savedText {
                    // Changed elsewhere. Unsaved edits here win; they're written out shortly.
                    if note.text == note.savedText { note.text = text }
                    note.savedText = text
                }
                loaded.append(note)
            } else if let index = gone.firstIndex(where: { $0.savedText == text }) {
                // Renamed elsewhere: same note, new name.
                var note = gone.remove(at: index)
                note.url = url
                loaded.append(note)
            } else {
                let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .now
                loaded.append(Note(id: UUID(), url: url, text: text, savedText: text, isOnDisk: true, created: created))
            }
        }
        loaded += notes.filter { !$0.isOnDisk }
        loaded.sort { $0.created < $1.created }
        if loaded != notes { notes = loaded }

        if current == nil {
            let remembered = UserDefaults.dynotch.string(forKey: Self.currentKey)
            currentID = notes.first { $0.url.lastPathComponent == remembered }?.id ?? notes.first?.id
        }
        if notes.isEmpty { newNote() }
    }

    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.3))
            guard !Task.isCancelled else { return }
            self?.reload()
        }
    }

    /// FSEvents with file-level events, which also catch files changed in place.
    private func watch() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let store = Unmanaged<NotesStore>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { store.scheduleReload() }
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(nil, callback, &context, [folder.path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    /// The single scratchpad Dynotch had before becomes the first note.
    private func migrateScratchpad() {
        let key = "notes.text"
        guard let text = UserDefaults.dynotch.string(forKey: key) else { return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            UserDefaults.dynotch.removeObject(forKey: key)
            return
        }
        let url = FileActions.uniqueURL(for: folder.appendingPathComponent(NoteLine.fileName(for: text) + ".md"))
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            UserDefaults.dynotch.removeObject(forKey: key)
            UserDefaults.dynotch.set(url.lastPathComponent, forKey: Self.currentKey)
        } catch {
            // Left in place for the next launch.
        }
    }

    // MARK: Snapshots

    func loadSample(_ texts: [String]) {
        notes = texts.enumerated().map { index, text in
            Note(id: UUID(), url: URL(fileURLWithPath: "/tmp/\(index).md"), text: text, savedText: text, isOnDisk: true,
                 created: Date(timeIntervalSinceReferenceDate: Double(index)))
        }
        currentID = notes.first?.id
    }
}

/// One line of a note: its indent, Markdown marker and text.
struct NoteLine: Equatable {
    enum Kind: Equatable {
        case text
        case heading
        case bullet
        case checklist(checked: Bool)
    }

    let kind: Kind
    /// Leading spaces and tabs.
    let indent: String
    /// "- [ ] ", "# ", "- " and so on, with the space after it.
    let marker: String
    let content: String

    init(_ line: some StringProtocol) {
        let line = String(line)
        let indent = String(line.prefix { $0 == " " || $0 == "\t" })
        let rest = line.dropFirst(indent.count)
        self.indent = indent
        if let bullet = rest.first, "-*+".contains(bullet), rest.dropFirst().first == " " {
            let afterBullet = rest.dropFirst(2)
            if afterBullet.count >= 3, afterBullet.first == "[", afterBullet.dropFirst(2).first == "]",
               let mark = afterBullet.dropFirst().first, " xX".contains(mark),
               afterBullet.count == 3 || afterBullet.dropFirst(3).first == " " {
                let markerLength = afterBullet.count == 3 ? 5 : 6
                kind = .checklist(checked: mark != " ")
                marker = String(rest.prefix(markerLength))
                content = String(rest.dropFirst(markerLength))
                return
            }
            kind = .bullet
            marker = String(rest.prefix(2))
            content = String(afterBullet)
            return
        }
        let hashes = rest.prefix { $0 == "#" }
        if (1...6).contains(hashes.count), rest.dropFirst(hashes.count).first == " " {
            kind = .heading
            marker = String(rest.prefix(hashes.count + 1))
            content = String(rest.dropFirst(hashes.count + 1))
            return
        }
        kind = .text
        marker = ""
        content = String(rest)
    }

    /// The first line with something in it, without its marker.
    static func title(of text: String) -> String {
        for line in text.split(whereSeparator: \.isNewline) {
            let content = NoteLine(line).content.trimmingCharacters(in: .whitespaces)
            if !content.isEmpty { return content }
        }
        return ""
    }

    /// A file name from the note's title: no slashes or colons, not too long, never empty.
    static func fileName(for text: String) -> String {
        var name = title(of: text)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        while name.hasPrefix(".") { name.removeFirst() }
        name = String(name.prefix(60)).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "Untitled" : name
    }
}
