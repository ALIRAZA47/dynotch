import AppKit
import Combine
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

/// Files parked in the notch. Items point at the original file unless the user
/// asked for copies; files the tray made itself live in its own folder.
@MainActor
final class TrayStore: ObservableObject {
    static let shared = TrayStore()

    struct Item: Identifiable, Codable, Equatable {
        let id: UUID
        var url: URL
        /// The tray created this file (a copy, a dropped image, an archive) and trashes it on removal.
        var isOwned: Bool
        var addedAt: Date
        /// Stays whatever the tidying says, and through Clear.
        var isPinned = false
        /// Came by itself, as a screenshot or a download, so tidying may take it away again.
        var isAutomatic = false
        /// What the file is, read off the main thread, as a tile draws it many times a second and the
        /// file can be on a disk that has gone away. Nil until it's been read, and never saved.
        var info: TrayFileInfo?

        private enum CodingKeys: String, CodingKey {
            case id, url, isOwned, addedAt, isPinned, isAutomatic
        }
    }

    @Published private(set) var items: [Item] = []
    /// The item the space bar previews in Quick Look.
    @Published private(set) var selection: Item.ID?

    /// ~/Library/Application Support/Dynotch/Tray
    let folder: URL
    private let indexURL: URL
    private var tidying: Poll?
    private var cancellables = Set<AnyCancellable>()
    /// Where the Tray's files are looked at: whether they're there, whose they are, how big. One at a
    /// time, so a disk that has gone away holds up only this.
    nonisolated private static let files = DispatchQueue(label: "app.dynotch.tray-files", qos: .utility)
    /// The latest look at the files. Each waits for the one before, so a test can wait for them all.
    private(set) var inspection: Task<Void, Never>?

    private convenience init() {
        self.init(support: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dynotch", isDirectory: true))
    }

    /// `support` holds the Tray's folder and its list. The tests pass one of their own.
    init(support: URL) {
        folder = support.appendingPathComponent("Tray", isDirectory: true)
        indexURL = support.appendingPathComponent("tray.json")
        keepFolderReal()
    }

    var urls: [URL] { items.map(\.url) }

    /// The saved list goes up at once. Whether each file is still there, and whether it's the Tray's
    /// own, is looked at off the main thread: this runs before the notch exists, and a file on a disk
    /// that has gone away would hold the app up until the disk timed out.
    func load() {
        if let data = try? Data(contentsOf: indexURL), let saved = try? JSONDecoder().decode([Item].self, from: data) {
            // Anything can edit the index, so what the tray owns (and may trash) comes from the path, not
            // the file. Until the path has been looked at, nothing is the Tray's to trash.
            items = saved.filter(\.url.isFileURL).map { item in
                var item = item
                item.isOwned = false
                return item
            }
            refreshFiles(droppingMissing: true)
            // Tidying may trash what the Tray owns, so it waits to know what that is.
            let looked = inspection
            Task { [weak self] in
                await looked?.value
                self?.tidy()
            }
        } else {
            tidy()
        }
        tidying = EnergyCoordinator.shared.schedule(.trayTidying) { [weak self] in self?.tidy() }
        AppSettings.shared.$trayKeeps
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.tidy() }
            .store(in: &cancellables)
    }

    /// Takes away the screenshots and downloads whose time is up, unless they're pinned. Their files
    /// stay where they are; copies the Tray made go to the Trash, as they do on Remove.
    func tidy(now: Date = .now) {
        guard let limit = AppSettings.shared.trayKeeps.seconds else { return }
        items.filter { $0.isAutomatic && !$0.isPinned && now.timeIntervalSince($0.addedAt) >= limit }
            .forEach(remove)
    }

    func add(_ urls: [URL], automatically: Bool = false) {
        // Putting a screenshot in by hand makes it yours, though it got there by itself first.
        if !automatically {
            for index in items.indices where urls.contains(items[index].url) { items[index].isAutomatic = false }
        }
        // Only what someone put here. What comes by itself comes from folders macOS keeps other apps
        // out of, and a copy in the Tray's folder would be outside that.
        let copies = AppSettings.shared.trayCopiesFiles && !automatically
        var added: [Item] = []
        for url in urls where !items.contains(where: { $0.url == url }) && !added.contains(where: { $0.url == url }) {
            if copies, !isInTrayFolder(url), let copy = try? copyIntoTray(url) {
                added.append(Item(id: UUID(), url: copy, isOwned: true, addedAt: .now, isAutomatic: automatically))
            } else {
                added.append(Item(id: UUID(), url: url, isOwned: isInTrayFolder(url), addedAt: .now, isAutomatic: automatically))
            }
        }
        if !added.isEmpty {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { items.append(contentsOf: added) }
            refreshFiles(of: Set(added.map(\.id)))
        }
        save()
    }

    /// Adds files a `dynotch://tray/add` link names. Anything on the Mac can send one, so they're only
    /// pointed at, never copied, nothing under ~/Library (where other apps' data lives behind
    /// macOS's permissions) is taken, and the notch says what arrived. The paths are looked at off the
    /// main thread, as a link can name a disk that has gone away; the task is for a test to wait on.
    @discardableResult
    func addFromScript(_ urls: [URL]) -> Task<Void, Never> {
        let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true)
            .standardizedFileURL.path + "/"
        let named = Array(urls.prefix(20))
        let folder = folder
        let previous = inspection
        let task = Task { [weak self] in
            await previous?.value
            let allowed: [(URL, Inspection)] = await Self.onFileQueue {
                // Resolving also corrects a path's case and takes it off the Data volume, which this relies on.
                named.map { $0.resolvingSymlinksInPath().standardizedFileURL }
                    .filter { FileManager.default.fileExists(atPath: $0.path) && !$0.path.hasPrefix(library) }
                    .map { ($0, Self.inspect($0, trayFolder: folder)) }
            }
            guard let self else { return }
            var fresh: [(URL, Inspection)] = []
            for (url, look) in allowed where !items.contains(where: { $0.url == url }) && !fresh.contains(where: { $0.0 == url }) {
                fresh.append((url, look))
            }
            guard !fresh.isEmpty else { return }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                self.items.append(contentsOf: fresh.map { Item(id: UUID(), url: $0.0, isOwned: $0.1.isOwned, addedAt: .now, info: $0.1.info) })
            }
            save()
            let detail = fresh.count == 1 ? "A script added \(fresh[0].0.lastPathComponent)" : "A script added \(fresh.count) files"
            LiveActivityCenter.shared.post(LiveNotice(key: "tray", symbol: "tray.and.arrow.down.fill", tint: .teal, text: "Tray",
                                                      detail: detail, fromScript: true, timing: .waits, recall: .whole), for: 4)
        }
        inspection = task
        return task
    }

    // MARK: Looking at the files

    /// What a look at one file found.
    struct Inspection: Sendable {
        var info: TrayFileInfo
        var isOwned: Bool
    }

    /// Reads every item's file again, or those of `ids`, off the main thread: its size, and whether
    /// it's the Tray's own. At launch, items whose files are gone are dropped, as they always were.
    @discardableResult
    func refreshFiles(of ids: Set<Item.ID>? = nil, droppingMissing: Bool = false) -> Task<Void, Never> {
        let targets = items.filter { ids?.contains($0.id) ?? true }.map { ($0.id, $0.url) }
        let folder = folder
        let previous = inspection
        let task = Task { [weak self] in
            await previous?.value
            guard !targets.isEmpty else { return }
            let looks = await Self.onFileQueue { targets.map { ($0.0, $0.1, Self.inspect($0.1, trayFolder: folder)) } }
            self?.apply(looks, droppingMissing: droppingMissing)
        }
        inspection = task
        return task
    }

    /// Only to items that still point where they were looked at: one may have moved or gone meanwhile.
    private func apply(_ looks: [(Item.ID, URL, Inspection)], droppingMissing: Bool) {
        var updated = items
        var missing = Set<Item.ID>()
        for (id, url, look) in looks {
            guard let index = updated.firstIndex(where: { $0.id == id }), updated[index].url == url else { continue }
            if droppingMissing, !look.info.exists {
                missing.insert(id)
                continue
            }
            updated[index].isOwned = look.isOwned
            updated[index].info = look.info
        }
        updated.removeAll { missing.contains($0.id) }
        if let selection, missing.contains(selection) { self.selection = nil }
        if updated != items { items = updated }
    }

    nonisolated private static func onFileQueue<Value>(_ work: @escaping @Sendable () -> Value) async -> Value {
        await withCheckedContinuation { continuation in
            files.async { continuation.resume(returning: work()) }
        }
    }

    nonisolated static func inspect(_ url: URL, trayFolder: URL) -> Inspection {
        Inspection(info: TrayFileInfo(reading: url), isOwned: isInside(url, folder: trayFolder))
    }

    /// Saves dropped data (an image from a browser, some text) as a file in the tray.
    func add(data: Data, named name: String) {
        let url = FileActions.uniqueURL(for: folder.appendingPathComponent(name))
        guard (try? data.write(to: url)) != nil else { return }
        add([url])
    }

    /// Takes away what a drop saved in the Tray's folder once it's been used, so that a file there
    /// always has an item. What came from anywhere else, or has an item of its own, stays.
    func removeLeftovers(of urls: [URL]) {
        let kept = Set(self.urls.map(\.standardizedFileURL))
        for url in urls where isInTrayFolder(url) && !kept.contains(url.standardizedFileURL) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func relocate(_ item: Item, to url: URL) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].url = url
        items[index].isOwned = isInTrayFolder(url)
        items[index].info = nil
        save()
        refreshFiles(of: [item.id])
    }

    func remove(_ item: Item) {
        if selection == item.id { selection = nil }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { items.removeAll { $0.id == item.id } }
        if item.isOwned { try? FileManager.default.trashItem(at: item.url, resultingItemURL: nil) }
        save()
    }

    /// Empties the tray, all but what's pinned.
    func clear() {
        for item in items where item.isOwned && !item.isPinned {
            try? FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
        }
        selection = nil
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { items.removeAll { !$0.isPinned } }
        save()
    }

    func togglePin(_ item: Item) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].isPinned.toggle()
        save()
    }

    func select(_ item: Item?) {
        selection = item?.id
    }

    /// Moves the selection to a neighbor, stopping at either end. With nothing selected, picks the first item.
    func moveSelection(by offset: Int) {
        guard let index = items.firstIndex(where: { $0.id == selection }) else {
            selection = items.first?.id
            return
        }
        selection = items[min(max(index + offset, 0), items.count - 1)].id
    }

    /// By where a path really leads, since a link in the folder could point anywhere.
    private func isInTrayFolder(_ url: URL) -> Bool {
        Self.isInside(url, folder: folder)
    }

    nonisolated private static func isInside(_ url: URL, folder: URL) -> Bool {
        url.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(folder.standardizedFileURL.resolvingSymlinksInPath().path + "/")
    }

    /// A link in the folder's place would send what's saved here to wherever it points, with all the
    /// app has been allowed. Removing a link leaves what it points at alone.
    private func keepFolderReal() {
        var info = stat()
        if lstat(folder.path, &info) == 0, info.st_mode & S_IFMT == S_IFLNK { try? FileManager.default.removeItem(at: folder) }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    private func copyIntoTray(_ url: URL) throws -> URL {
        keepFolderReal()
        let target = FileActions.uniqueURL(for: folder.appendingPathComponent(url.lastPathComponent))
        try FileManager.default.copyItem(at: url, to: target)
        return target
    }

    private func save() {
        try? JSONEncoder().encode(items).write(to: indexURL, options: .atomic)
    }

    // MARK: Snapshots

    /// Read at once: the samples are in a scratch folder, and a snapshot draws them straight away.
    func loadSample(_ urls: [URL]) {
        items = urls.map { Item(id: UUID(), url: $0, isOwned: false, addedAt: .now, info: TrayFileInfo(reading: $0)) }
    }

    /// Pins the sample at `index`, unpinning the others. Nothing is saved.
    func loadSample(pinned index: Int?) {
        for position in items.indices { items[position].isPinned = position == index }
    }
}

extension TrayStore.Item {
    /// Lists saved before pinning have neither flag.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        url = try container.decode(URL.self, forKey: .url)
        isOwned = try container.decode(Bool.self, forKey: .isOwned)
        addedAt = try container.decode(Date.self, forKey: .addedAt)
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        isAutomatic = try container.decodeIfPresent(Bool.self, forKey: .isAutomatic) ?? false
    }
}

/// Quick Look thumbnails for tray items, falling back to the Finder icon. Both are made off the main
/// thread, as either reads the file; until one arrives, the file's type has a generic icon.
@MainActor
final class ThumbnailCache: ObservableObject {
    static let shared = ThumbnailCache()

    private var thumbnails: [URL: NSImage] = [:]
    private var icons: [URL: NSImage] = [:]
    private var requested: Set<URL> = []
    private var typeIcons: [String: NSImage] = [:]
    nonisolated private static let iconQueue = DispatchQueue(label: "app.dynotch.tray-icons", qos: .utility)
    private static let side: CGFloat = 46

    func image(for url: URL) -> NSImage {
        if let thumbnail = thumbnails[url] { return thumbnail }
        if requested.insert(url).inserted {
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 88, height: 88), scale: 2,
                                                       representationTypes: .thumbnail)
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
                guard let thumbnail = representation?.cgImage else {
                    Self.iconQueue.async { [weak self] in
                        let icon = NSWorkspace.shared.icon(forFile: url.path).flattened(side: Self.side)
                        DispatchQueue.main.async { [weak self] in
                            MainActor.assumeIsolated {
                                self?.icons[url] = icon
                                self?.objectWillChange.send()
                            }
                        }
                    }
                    return
                }
                let image = CGColorSpace(name: CGColorSpace.sRGB).flatMap { thumbnail.copy(colorSpace: $0) } ?? thumbnail
                Task { @MainActor in
                    self?.thumbnails[url] = NSImage(cgImage: image, size: .zero)
                    self?.objectWillChange.send()
                }
            }
        }
        return icons[url] ?? typeIcon(for: url)
    }

    /// By the name's extension alone, which needs nothing from the disk.
    private func typeIcon(for url: URL) -> NSImage {
        let type = url.hasDirectoryPath ? UTType.folder
            : url.pathExtension.isEmpty ? UTType.data : UTType(filenameExtension: url.pathExtension) ?? .data
        if let icon = typeIcons[type.identifier] { return icon }
        let icon = NSWorkspace.shared.icon(for: type).flattened(side: Self.side)
        typeIcons[type.identifier] = icon
        return icon
    }
}

/// Whether a drag holds an image, looked at once per drag. The drag pasteboard is read on every drag
/// event, and its items come from the app the drag started in.
struct DragImageCheck {
    private var changeCount: Int?
    private var holdsImages = false

    mutating func holdsImages(on pasteboard: NSPasteboard, look: (NSPasteboard) -> Bool = TrayDrop.holdsImages) -> Bool {
        holdsImages(on: pasteboard, changeCount: pasteboard.changeCount, look: look)
    }

    /// With the change count the caller has just read, so it isn't asked for twice.
    mutating func holdsImages(on pasteboard: NSPasteboard, changeCount current: Int,
                              look: (NSPasteboard) -> Bool = TrayDrop.holdsImages) -> Bool {
        if current != changeCount {
            changeCount = current
            holdsImages = look(pasteboard)
        }
        return holdsImages
    }
}

/// Whether a drag carries something the Tray takes, looked at once per drag. The pasteboard's types
/// come from the app the drag started in, and the notch asks on every drag event near it.
struct FileDragCheck {
    private var changeCount: Int?
    private var carries = false

    /// What the Tray takes: files, and pictures from a browser or an editor.
    static func accepts(_ types: [NSPasteboard.PasteboardType]) -> Bool {
        types.contains(.fileURL) || types.contains(.png) || types.contains(.tiff)
    }

    /// `types` is only read when `changeCount` is new: a new drag.
    mutating func carriesFiles(changeCount current: Int, types: () -> [NSPasteboard.PasteboardType]) -> Bool {
        if current != changeCount {
            changeCount = current
            carries = Self.accepts(types())
        }
        return carries
    }
}

/// Turns whatever was dropped on the notch into file URLs.
enum TrayDrop {
    static let types: [UTType] = [.fileURL, .image, .url, .plainText]

    /// Whether an image is among what's on the pasteboard, going by each item as `urls` will when it's
    /// dropped: a file by its type, and anything else by its data. In that order, as a file can carry
    /// a picture of its icon, which doesn't make a PDF an image. Finder's file URLs are reference URLs,
    /// which have no extension to go by until they're turned into paths.
    ///
    /// What an item says it holds is asked first, for all of them: a picture says so by its type, and
    /// that needs nothing from the app the drag came from. Only then are file links read, which an app
    /// that makes its data when asked would have to make.
    static func holdsImages(_ pasteboard: NSPasteboard) -> Bool {
        let items = pasteboard.pasteboardItems ?? []
        let declared = items.map(\.types)
        if declared.contains(where: { !$0.contains(.fileURL) && ($0.contains(.png) || $0.contains(.tiff)) }) { return true }
        return zip(items, declared).contains { item, types in
            guard types.contains(.fileURL) else { return false }
            guard let link = item.string(forType: .fileURL) else { return types.contains(.png) || types.contains(.tiff) }
            return (URL(string: link) as NSURL?)?.filePathURL.map(FileActions.isImage) == true
        }
    }

    @MainActor
    static func urls(from providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                if let url = await loadFileURL(provider) { urls.append(url) }
            } else if let type = provider.registeredTypeIdentifiers.compactMap({ UTType($0) }).first(where: { $0.conforms(to: .image) }) {
                if let data = await loadData(provider, type: type),
                   let url = save(data, named: "Image \(timestamp()).\(type.preferredFilenameExtension ?? "png")") {
                    urls.append(url)
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                // A link from a browser becomes a .webloc, like dropping it in Finder.
                if let data = await loadData(provider, type: .url),
                   let link = URL(dataRepresentation: data, relativeTo: nil),
                   let plist = try? PropertyListSerialization.data(fromPropertyList: ["URL": link.absoluteString], format: .xml, options: 0),
                   let url = save(plist, named: "\(Self.fileName(forLinkTo: link.host)).webloc") {
                    urls.append(url)
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                var data = await loadData(provider, type: .utf8PlainText)
                if data == nil { data = await loadData(provider, type: .plainText) }
                if let data, let url = save(data, named: "Text \(timestamp()).txt") { urls.append(url) }
            }
        }
        return urls
    }

    private static func loadFileURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
        }
    }

    private static func loadData(_ provider: NSItemProvider, type: UTType) async -> Data? {
        await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }

    @MainActor
    private static func save(_ data: Data, named name: String) -> URL? {
        let url = FileActions.uniqueURL(for: TrayStore.shared.folder.appendingPathComponent(name))
        return (try? data.write(to: url)) != nil ? url : nil
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter.string(from: .now)
    }

    /// A name for a dropped link's file, from its host. Only what a host name is made of gets
    /// through, so a link can't name its way out of the Tray's folder.
    static func fileName(forLinkTo host: String?) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-"))
        let name = String((host ?? "").unicodeScalars.filter(allowed.contains).map(Character.init).prefix(80))
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return name.isEmpty ? "Link" : name
    }
}
