import AppKit
import Combine
import CoreServices

/// Notes as Markdown files in a folder: Dynotch's own, or one the user picks. A folder in iCloud
/// Drive syncs them between Macs. Edits are saved as you type, and changes made on disk, by
/// another app or another Mac, show up as they land.
///
/// The folder is listed and read on a queue of its own, never on the main thread: a note in iCloud
/// that isn't downloaded yet blocks whoever reads it, and a shared folder can change many times a
/// second. A file is only read again when its modification date or size moved.
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

    /// The notes that stayed in the last folder left that had any.
    struct LeftBehind: Equatable {
        let folder: URL
        let count: Int
    }

    @Published private(set) var notes: [Note] = []
    @Published private(set) var currentID: Note.ID?
    @Published private(set) var folder: URL
    /// The last save failed, say because the folder went away.
    @Published private(set) var saveFailed = false
    /// The folder in use starts out without these, so Settings says where they are.
    @Published private(set) var leftBehind: LeftBehind?

    /// ~/Library/Application Support/Dynotch/Notes
    let defaultFolder: URL
    /// How long after a failed save it's tried again.
    var retryDelay: Duration = .seconds(30)

    /// Reads a note file's bytes. The tests count reads through it.
    typealias Reader = @Sendable (URL) throws -> Data
    /// Moves a file to the Trash. The tests keep it away from the real one.
    typealias Trasher = (URL) throws -> Void

    /// A reload shows at most this many notes, the most recently changed, and reads no file larger
    /// than `maxFileBytes`. A larger file is left out, never read in part, so it's never saved back short.
    nonisolated static let maxNotes = 500
    nonisolated static let maxFileBytes = 4 << 20

    private var stream: FSEventStreamRef?
    /// The folder's path as the stream reports it, which resolves links such as /var to /private/var.
    private var watchedPaths: [String] = []
    private var saveTasks: [Note.ID: Task<Void, Never>] = [:]
    private var reloadTask: Task<Void, Never>?
    private let reader: Reader
    private let trash: Trasher
    private let diskQueue = DispatchQueue(label: "app.dynotch.notes", qos: .utility)
    /// What each file held when it was last read or written here, by standardized path.
    private var fileCache: [String: CachedFile] = [:]
    /// Counts this store's own writes, moves and removals, so a listing taken before one is thrown away.
    private var diskChanges = 0
    private var reloading: Task<Void, Never>?
    private var reloadAgain = false
    /// Files this store created since launch: only those are removed outright when left empty.
    private var createdHere: Set<String> = []
    /// How many times the folder has been listed, for the tests.
    private(set) var scans = 0
    private var terminationObserver: NSObjectProtocol?
    /// The chosen folder was gone at launch, so Dynotch's own is in use.
    private let folderWasMissing: Bool

    private static let currentKey = "notes.current"

    private init() {
        reader = Self.readFile
        trash = Self.moveToTrash
        defaultFolder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dynotch/Notes", isDirectory: true)
        // Anything can write a path into the defaults; only a folder that's there is used, and it's
        // never created or written to on the strength of the setting alone.
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

    /// A store that keeps to `folder`, for the tests, which must never reach the real notes.
    init(folder: URL, defaultFolder: URL? = nil, reader: @escaping Reader = NotesStore.readFile,
         trash: @escaping Trasher = NotesStore.moveToTrash) {
        self.defaultFolder = defaultFolder ?? folder
        self.folder = folder
        self.reader = reader
        self.trash = trash
        folderWasMissing = false
    }

    nonisolated static let readFile: Reader = { try Data(contentsOf: $0) }

    nonisolated static func moveToTrash(_ url: URL) throws { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }

    var current: Note? { notes.first { $0.id == currentID } }

    var isUsingDefaultFolder: Bool { folder.standardizedFileURL == defaultFolder.standardizedFileURL }

    func start() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        migrateScratchpad()
        reload()
        watch()
        if folderWasMissing {
            LiveActivityCenter.shared.post(LiveNotice(key: "notes", symbol: "note.text", tint: .yellow, text: "Notes",
                                                      detail: "The notes folder is gone; using Dynotch's own",
                                                      timing: .waits, recall: .whole), for: 5)
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
        scheduleSave(id, after: .seconds(0.6))
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
        if note.isOnDisk {
            diskChanges += 1
            try? trash(note.url)
            forget(note.url)
        }
        if notes.isEmpty {
            newNote()
        } else if currentID == id {
            setCurrent(notes[min(index, notes.count - 1)].id)
        }
    }

    // MARK: Folder

    /// Keeps notes in `newFolder`, or in Dynotch's own folder when it's nil. Notes in Dynotch's own
    /// folder move along. Any other folder is left as it is: it may be a vault of other Markdown, or
    /// in iCloud Drive for another Mac, so its notes only move on `bringLeftBehind`.
    func useFolder(_ newFolder: URL?) {
        let target = (newFolder ?? defaultFolder).standardizedFileURL
        guard target != folder.standardizedFileURL else { return }
        saveAll()
        try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let saved = notes.filter(\.isOnDisk)
        if isUsingDefaultFolder {
            move(saved.map(\.url), to: target)
        } else if !saved.isEmpty {
            leftBehind = LeftBehind(folder: folder, count: saved.count)
        }
        if leftBehind?.folder.standardizedFileURL == target { leftBehind = nil }
        AppSettings.shared.notesFolderPath = newFolder == nil ? "" : target.path
        folder = target
        notes = []
        fileCache = [:]
        createdHere = []
        reload()
        watch()
    }

    /// Moves the notes left behind into the folder in use.
    func bringLeftBehind() {
        guard let leftBehind else { return }
        saveAll()
        move(Self.noteFiles(in: leftBehind.folder) ?? [], to: folder)
        self.leftBehind = nil
        notes = []
        reload()
    }

    private func move(_ files: [URL], to target: URL) {
        diskChanges += 1
        for file in files {
            let destination = FileActions.uniqueURL(for: target.appendingPathComponent(file.lastPathComponent))
            try? FileManager.default.moveItem(at: file, to: destination)
        }
    }

    /// iCloud Drive's "Dynotch Notes" folder, if iCloud Drive is on.
    var iCloudFolder: URL? {
        let drive = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        guard FileManager.default.fileExists(atPath: drive.path) else { return nil }
        return drive.appendingPathComponent("Dynotch Notes", isDirectory: true)
    }

    var isInICloud: Bool { Self.isInICloud(folder) }

    static func isInICloud(_ folder: URL) -> Bool {
        folder.path.contains("/Library/Mobile Documents/")
    }

    // MARK: Saving

    func saveAll() {
        saveTasks.values.forEach { $0.cancel() }
        saveTasks.removeAll()
        // Every note, not just those with a save waiting: `save` passes over the ones with nothing new.
        notes.map(\.id).forEach(save)
    }

    private func scheduleSave(_ id: Note.ID, after delay: Duration) {
        saveTasks[id]?.cancel()
        saveTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.save(id)
        }
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
                if note.isOnDisk {
                    diskChanges += 1
                    try FileManager.default.moveItem(at: url, to: target)
                    moved(from: url, to: target)
                    // Now, so that a retry after a failed write doesn't look for the old name.
                    notes[index].url = target
                }
                url = target
            }
            diskChanges += 1
            try note.text.write(to: url, atomically: true, encoding: .utf8)
            if !note.isOnDisk { createdHere.insert(Self.key(url)) }
            remember(url, text: note.text)
            notes[index].url = url
            notes[index].savedText = note.text
            notes[index].isOnDisk = true
            saveFailed = false
            if id == currentID { UserDefaults.dynotch.set(url.lastPathComponent, forKey: Self.currentKey) }
        } catch {
            saveFailed = true
            scheduleSave(id, after: retryDelay)
        }
    }

    /// The file as just written, so the event the write causes reads nothing.
    private func remember(_ url: URL, text: String) {
        // A URL of its own: resource values are cached on the URL they're read through.
        let values = try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        fileCache[Self.key(url)] = CachedFile(stamp: FileStamp(date: values?.contentModificationDate, size: values?.fileSize),
                                              text: text)
    }

    private func moved(from old: URL, to new: URL) {
        // A rename keeps the date and size.
        fileCache[Self.key(new)] = fileCache.removeValue(forKey: Self.key(old))
        if createdHere.remove(Self.key(old)) != nil { createdHere.insert(Self.key(new)) }
    }

    private func forget(_ url: URL) {
        fileCache[Self.key(url)] = nil
        createdHere.remove(Self.key(url))
    }

    private nonisolated static func key(_ url: URL) -> String { url.standardizedFileURL.path }

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

    /// An empty note goes away once you leave it, file and all. A file this store made since launch is
    /// removed; any other, which another app may have put there, goes to the Trash.
    private func discardIfBlank(_ id: Note.ID) {
        guard let index = notes.firstIndex(where: { $0.id == id }), notes[index].isBlank, notes.count > 1 else { return }
        saveTasks[id]?.cancel()
        let note = notes.remove(at: index)
        guard note.isOnDisk else { return }
        let onDisk = (try? String(contentsOf: note.url, encoding: .utf8)) ?? ""
        if onDisk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            diskChanges += 1
            if createdHere.contains(Self.key(note.url)) {
                try? FileManager.default.removeItem(at: note.url)
            } else {
                try? trash(note.url)
            }
            forget(note.url)
        }
    }

    // MARK: Loading

    /// A file's modification date and size: when neither moved, it holds what it held.
    struct FileStamp: Equatable, Sendable {
        var date: Date?
        var size: Int?

        /// Only a stamp with both parts says a file is unchanged.
        func matches(_ other: FileStamp) -> Bool { date != nil && size != nil && self == other }
    }

    struct CachedFile: Sendable {
        var stamp: FileStamp
        /// Nil when the file was read but isn't UTF-8 text.
        var text: String?
    }

    /// One Markdown file in the folder, as a scan found it.
    struct ScannedFile: Sendable {
        let url: URL
        /// Nil when it wasn't read this time: not downloaded, not text, past `maxNotes`, or not readable.
        let text: String?
        let created: Date
    }

    struct Scan: Sendable {
        /// Nil when the folder couldn't be listed, which isn't the same as having no notes.
        let files: [ScannedFile]?
        let cache: [String: CachedFile]
    }

    /// Reads every Markdown file in the folder that changed since it was last read, on the notes queue.
    /// Notes edited here keep their edits; others take what's on disk. The task ends once the notes are
    /// up to date; calls while one runs fold into it.
    @discardableResult
    func reload() -> Task<Void, Never> {
        reloadAgain = true
        if let reloading { return reloading }
        let task = Task { [weak self] in
            while let store = self, store.reloadAgain {
                store.reloadAgain = false
                await store.reloadOnce()
            }
            self?.reloading = nil
        }
        reloading = task
        return task
    }

    private func reloadOnce() async {
        let folder = folder, changes = diskChanges, cache = fileCache, reader = reader
        scans += 1
        let scan = await withCheckedContinuation { (continuation: CheckedContinuation<Scan, Never>) in
            diskQueue.async { continuation.resume(returning: Self.scan(folder, cache: cache, reader: reader)) }
        }
        // A save, rename or removal here while the folder was being read, or a new folder: what the scan
        // saw is already out of date, and taking it would undo the change. The change's own event, or
        // this, looks again.
        guard folder == self.folder, changes == diskChanges else {
            if folder == self.folder { scheduleReload() }
            return
        }
        fileCache = scan.cache
        apply(scan.files)
    }

    /// Lists the folder and reads what changed, off the main thread. Files whose date and size match
    /// `cache` aren't read again, files not downloaded from iCloud are asked for and read once their
    /// event comes in, and files over `maxFileBytes` are left out.
    nonisolated static func scan(_ folder: URL, cache: [String: CachedFile], reader: Reader) -> Scan {
        let keys: [URLResourceKey] = [.creationDateKey, .contentModificationDateKey, .fileSizeKey, .isDirectoryKey,
                                      .ubiquitousItemDownloadingStatusKey]
        guard let listed = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                         options: [.skipsHiddenFiles]) else {
            return Scan(files: nil, cache: cache)
        }
        let entries = listed.filter { isNoteName($0.lastPathComponent) }
            .map { url in (url: url, values: try? url.resourceValues(forKeys: Set(keys))) }
            .filter { $0.values?.isDirectory != true }
            // The most recently changed first, so `maxNotes` keeps those.
            .sorted { ($0.values?.contentModificationDate ?? .distantPast) > ($1.values?.contentModificationDate ?? .distantPast) }
        var files: [ScannedFile] = []
        var fresh: [String: CachedFile] = [:]
        for (position, entry) in entries.enumerated() {
            let url = entry.url, values = entry.values
            let path = key(url)
            let stamp = FileStamp(date: values?.contentModificationDate, size: values?.fileSize)
            let created = values?.creationDate ?? .now
            if let cached = cache[path], cached.stamp.matches(stamp) {
                fresh[path] = cached
                files.append(ScannedFile(url: url, text: cached.text, created: created))
                continue
            }
            // Too big to be a note: left out whole, so it can't come back cut short.
            if let size = values?.fileSize, size > maxFileBytes { continue }
            guard position < maxNotes else {
                files.append(ScannedFile(url: url, text: nil, created: created))
                continue
            }
            if let status = values?.ubiquitousItemDownloadingStatus, status != .current {
                // Reading it would wait for iCloud. Its event comes in once it's here.
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
                files.append(ScannedFile(url: url, text: nil, created: created))
                continue
            }
            guard let data = try? reader(url) else {
                // Not readable just now; tried again next time.
                files.append(ScannedFile(url: url, text: nil, created: created))
                continue
            }
            let text = String(data: data, encoding: .utf8)
            fresh[path] = CachedFile(stamp: stamp, text: text)
            files.append(ScannedFile(url: url, text: text, created: created))
        }
        return Scan(files: files, cache: fresh)
    }

    /// Takes what a scan found. Notes edited here keep their edits; others take what's on disk.
    private func apply(_ scanned: [ScannedFile]?) {
        // A folder that can't be read just now says nothing about its notes, so they stay as they are.
        guard let files = scanned else {
            if notes.isEmpty { newNote() }
            return
        }
        let paths = Set(files.map { Self.key($0.url) })
        let known = Dictionary(notes.map { (Self.key($0.url), $0) }, uniquingKeysWith: { first, _ in first })
        var gone = notes.filter { $0.isOnDisk && !paths.contains(Self.key($0.url)) }
        var loaded: [Note] = []
        for file in files {
            let url = file.url
            guard let text = file.text else {
                // Not readable as text just now. A note we have keeps what it has.
                if let note = known[Self.key(url)], note.isOnDisk { loaded.append(note) }
                continue
            }
            if var note = known[Self.key(url)] {
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
                loaded.append(Note(id: UUID(), url: url, text: text, savedText: text, isOnDisk: true, created: file.created))
            }
        }
        // Gone from the folder with edits that never reached it: they stay, and save as a new file.
        for var note in gone where note.text != note.savedText && !note.isBlank {
            note.isOnDisk = false
            loaded.append(note)
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

    /// The folder's notes, or nil when it can't be listed, which isn't the same as having none.
    private static func noteFiles(in folder: URL) -> [URL]? {
        let keys: [URLResourceKey] = [.creationDateKey, .isRegularFileKey]
        return (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                             options: [.skipsHiddenFiles]))?
            .filter { isNoteName($0.lastPathComponent) }
    }

    /// The names a listing keeps: Markdown, and not hidden.
    nonisolated static func isNoteName(_ name: String) -> Bool {
        !name.hasPrefix(".") && ["md", "markdown"].contains((name as NSString).pathExtension.lowercased())
    }

    /// Whether a file event can change the notes: one for a note file right in the folder, or one that
    /// says events were lost. Files in folders inside it, hidden files and other kinds are passed over.
    nonisolated static func eventMatters(_ path: String, flags: FSEventStreamEventFlags, folderPaths: [String]) -> Bool {
        let rescan = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                                             | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged)
        if flags & rescan != 0 { return true }
        var path = path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        let parent = (path as NSString).deletingLastPathComponent
        guard folderPaths.contains(where: { $0.caseInsensitiveCompare(parent) == .orderedSame }) else { return false }
        return isNoteName((path as NSString).lastPathComponent)
    }

    /// The folder's path as written and with its links resolved, since events name the real path.
    private static func paths(of folder: URL) -> [String] {
        var paths = [folder.standardizedFileURL.path]
        if let real = realpath(folder.path, nil) {
            paths.append(String(cString: real))
            free(real)
        }
        return paths.map { $0.count > 1 && $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
    }

    /// Schedules a reload when any of the events can change the notes. Says whether it did.
    @discardableResult
    func handleEvents(_ paths: [String], flags: [FSEventStreamEventFlags]) -> Bool {
        let folderPaths = watchedPaths.isEmpty ? Self.paths(of: folder) : watchedPaths
        let matters = paths.indices.contains { index in
            Self.eventMatters(paths[index], flags: flags.indices.contains(index) ? flags[index] : 0, folderPaths: folderPaths)
        }
        if matters { scheduleReload() }
        return matters
    }

    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.3))
            guard !Task.isCancelled else { return }
            self?.reload()
        }
    }

    /// FSEvents with file-level events, which also catch files changed in place. The stream covers the
    /// folder's subfolders too; `handleEvents` passes over what happens in them.
    private func watch() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        watchedPaths = Self.paths(of: folder)
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
            guard let info else { return }
            let store = Unmanaged<NotesStore>.fromOpaque(info).takeUnretainedValue()
            let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String] ?? []
            let flags = Array(UnsafeBufferPointer(start: eventFlags, count: count))
            MainActor.assumeIsolated { _ = store.handleEvents(paths, flags: flags) }
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
                                             | kFSEventStreamCreateFlagUseCFTypes)
        guard let stream = FSEventStreamCreate(nil, callback, &context, [folder.path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    /// The single scratchpad Dynotch had before becomes the first note, in Dynotch's own folder: the
    /// text and a chosen folder are both in the defaults, so a chosen one could be anywhere.
    func migrateScratchpad() {
        let key = "notes.text"
        guard isUsingDefaultFolder, let text = UserDefaults.dynotch.string(forKey: key) else { return }
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

    /// `created` dates the notes, oldest first; without it they're as old as the reference date.
    /// `current` is the one open.
    func loadSample(_ texts: [String], created: [Date]? = nil, current: Int = 0) {
        notes = texts.enumerated().map { index, text in
            Note(id: UUID(), url: URL(fileURLWithPath: "/tmp/\(index).md"), text: text, savedText: text, isOnDisk: true,
                 created: created.flatMap { $0.indices.contains(index) ? $0[index] : nil }
                    ?? Date(timeIntervalSinceReferenceDate: Double(index)))
        }
        currentID = notes.indices.contains(current) ? notes[current].id : notes.first?.id
    }

    func loadSample(leftBehind: LeftBehind?) {
        self.leftBehind = leftBehind
    }

    func loadSample(saveFailed: Bool) {
        self.saveFailed = saveFailed
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
