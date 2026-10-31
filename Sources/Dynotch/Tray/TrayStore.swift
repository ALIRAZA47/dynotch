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
    }

    @Published private(set) var items: [Item] = []
    /// The item the space bar previews in Quick Look.
    @Published private(set) var selection: Item.ID?

    /// ~/Library/Application Support/Dynotch/Tray
    let folder: URL
    private let indexURL: URL
    private var tidying: Poll?
    private var cancellables = Set<AnyCancellable>()

    private convenience init() {
        self.init(support: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dynotch", isDirectory: true))
    }

    /// `support` holds the Tray's folder and its list. The tests pass one of their own.
    init(support: URL) {
        folder = support.appendingPathComponent("Tray", isDirectory: true)
        indexURL = support.appendingPathComponent("tray.json")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    var urls: [URL] { items.map(\.url) }

    func load() {
        if let data = try? Data(contentsOf: indexURL), let saved = try? JSONDecoder().decode([Item].self, from: data) {
            // Anything can edit the index, so what the tray owns (and may trash) comes from the path, not the file.
            items = saved.filter { $0.url.isFileURL && FileManager.default.fileExists(atPath: $0.url.path) }
                .map { item in
                    var item = item
                    item.isOwned = isInTrayFolder(item.url)
                    return item
                }
        }
        tidy()
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
        let copies = AppSettings.shared.trayCopiesFiles
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
        }
        save()
    }

    /// Adds files a `dynotch://tray/add` link names. Anything on the Mac can send one, so they're only
    /// pointed at, never copied, nothing under ~/Library (where other apps' data lives behind
    /// macOS's permissions) is taken, and the notch says what arrived.
    func addFromScript(_ urls: [URL]) {
        let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true)
            .standardizedFileURL.path + "/"
        let allowed = urls.prefix(20).map { $0.resolvingSymlinksInPath().standardizedFileURL }
            .filter { FileManager.default.fileExists(atPath: $0.path) && !$0.path.hasPrefix(library) }
        let fresh = allowed.filter { url in !items.contains { $0.url == url } }
        guard !fresh.isEmpty else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            items.append(contentsOf: fresh.map { Item(id: UUID(), url: $0, isOwned: isInTrayFolder($0), addedAt: .now) })
        }
        save()
        let detail = fresh.count == 1 ? "A script added \(fresh[0].lastPathComponent)" : "A script added \(fresh.count) files"
        LiveActivityCenter.shared.post(LiveNotice(key: "tray", symbol: "tray.and.arrow.down.fill", tint: .teal, text: "Tray",
                                                  detail: detail, fromScript: true, timing: .waits, recall: .whole), for: 4)
    }

    /// Saves dropped data (an image from a browser, some text) as a file in the tray.
    func add(data: Data, named name: String) {
        let url = FileActions.uniqueURL(for: folder.appendingPathComponent(name))
        guard (try? data.write(to: url)) != nil else { return }
        add([url])
    }

    func relocate(_ item: Item, to url: URL) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].url = url
        items[index].isOwned = isInTrayFolder(url)
        save()
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

    private func isInTrayFolder(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path + "/")
    }

    private func copyIntoTray(_ url: URL) throws -> URL {
        let target = FileActions.uniqueURL(for: folder.appendingPathComponent(url.lastPathComponent))
        try FileManager.default.copyItem(at: url, to: target)
        return target
    }

    private func save() {
        try? JSONEncoder().encode(items).write(to: indexURL, options: .atomic)
    }

    // MARK: Snapshots

    func loadSample(_ urls: [URL]) {
        items = urls.map { Item(id: UUID(), url: $0, isOwned: false, addedAt: .now) }
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

/// Quick Look thumbnails for tray items, falling back to the Finder icon.
@MainActor
final class ThumbnailCache: ObservableObject {
    static let shared = ThumbnailCache()

    private var thumbnails: [URL: NSImage] = [:]
    private var requested: Set<URL> = []

    func image(for url: URL) -> NSImage {
        if let thumbnail = thumbnails[url] { return thumbnail }
        if requested.insert(url).inserted {
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 88, height: 88), scale: 2,
                                                       representationTypes: .thumbnail)
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
                guard let thumbnail = representation?.cgImage else { return }
                let image = CGColorSpace(name: CGColorSpace.sRGB).flatMap { thumbnail.copy(colorSpace: $0) } ?? thumbnail
                Task { @MainActor in
                    self?.thumbnails[url] = NSImage(cgImage: image, size: .zero)
                    self?.objectWillChange.send()
                }
            }
        }
        return IconCache.icon(forFile: url.path, side: 46)
    }
}

/// Turns whatever was dropped on the notch into file URLs.
enum TrayDrop {
    static let types: [UTType] = [.fileURL, .image, .url, .plainText]

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
                   let url = save(plist, named: "\(link.host ?? "Link").webloc") {
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
}
