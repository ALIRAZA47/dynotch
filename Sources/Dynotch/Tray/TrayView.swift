import SwiftUI
import UniformTypeIdentifiers

/// The Tray section: parked files as tiles, or drop zones while files are dragged in. What's been
/// copied is the Clipboard section's now.
struct TrayTabView: View {
    @ObservedObject var viewModel: NotchViewModel

    var body: some View {
        if viewModel.isDraggingFiles {
            TrayDropZones(viewModel: viewModel)
                .orbitHeader("Tray", subtitle: "Drop on what to do")
                .transition(.opacity)
        } else {
            TrayContentView(viewModel: viewModel)
                .transition(.opacity)
        }
    }
}

private struct TrayContentView: View {
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject private var tray = TrayStore.shared
    @ViewState private var isTargeted = false
    @ViewState private var isWorking = false
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.notchTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: NotchTheme.gap) {
            if tray.items.isEmpty {
                AddFilesStrip(isTargeted: isTargeted, isAlone: true)
                    .frame(maxHeight: .infinity)
            } else {
                grid
                AddFilesStrip(isTargeted: isTargeted, isAlone: false)
                    .frame(height: 40)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .trayDropTarget(isTargeted: $isTargeted) { providers in
            Task { TrayStore.shared.add(await TrayDrop.urls(from: providers)) }
            return true
        }
        .animation(.notchToggle, value: isTargeted)
        .background {
            if !isSnapshot { QuickLookAnchor(viewModel: viewModel) }
        }
        .orbitHeader("Tray", subtitle: subtitle) { actions }
        // Sizes are read off the main thread and kept; a file may have changed since they were.
        .onAppear { if !isSnapshot { tray.refreshFiles() } }
    }

    /// "6 files · 41.2 MB · 2 new".
    private var subtitle: String {
        let items = tray.items
        guard !items.isEmpty else { return "Empty" }
        var parts = [items.count == 1 ? "1 file" : "\(items.count) files"]
        let bytes = items.compactMap { $0.info?.bytes }.reduce(0, +)
        if bytes > 0 { parts.append(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) }
        let new = items.filter { TrayFileInfo.isNew($0, now: now) }.count
        if new > 0 { parts.append("\(new) new") }
        return parts.joined(separator: " · ")
    }

    private var now: Date { isSnapshot ? SnapshotClock.now : .now }

    /// The files as tiles, as many to a row as fit, scrolling down when there are more.
    private var grid: some View {
        GeometryReader { proxy in
            let spacing: CGFloat = 8
            let columns = max(1, Int((proxy.size.width + spacing) / (TrayTile.minimumWidth + spacing)))
            let width = ((proxy.size.width - spacing * CGFloat(columns - 1)) / CGFloat(columns)).rounded(.down)
            let rows = stride(from: 0, to: tray.items.count, by: columns).map { Array(tray.items[$0..<min($0 + columns, tray.items.count)]) }
            Scroller(.vertical, fadesOverflow: true) {
                VStack(alignment: .leading, spacing: spacing) {
                    ForEach(rows, id: \.first?.id) { row in
                        HStack(spacing: spacing) {
                            ForEach(row) { item in
                                TrayTile(item: item, isSelected: tray.selection == item.id, isNew: TrayFileInfo.isNew(item, now: now),
                                         forcesHover: isSnapshot && TraySnapshot.hoveredFile == tray.items.firstIndex(of: item),
                                         viewModel: viewModel)
                                    .frame(width: width)
                                    .transition(reduceMotion ? AnyTransition.opacity : .scale(scale: 0.8).combined(with: .opacity))
                            }
                        }
                    }
                }
                // Room for the selection ring, which reaches past a tile's edge.
                .padding(2)
                .frame(width: proxy.size.width + 4, alignment: .leading)
                .accessibilityElement(children: .contain)
            }
            .padding(-2)
        }
        .frame(minHeight: TrayTile.height)
        // As tall as the rows, so the strip sits right under them, and no taller than the room.
        .frame(maxHeight: gridHeight)
    }

    /// The rows' height at the panel's width.
    private var gridHeight: CGFloat {
        let width = AppSettings.shared.openWidth - NotchTheme.inset * 2
        let columns = max(1, Int((width + 8) / (TrayTile.minimumWidth + 8)))
        let rows = (tray.items.count + columns - 1) / columns
        return CGFloat(rows) * TrayTile.height + CGFloat(max(0, rows - 1)) * 8
    }

    /// AirDrop, Share and Compress for every file, and Clear. Spelled out where the band has room,
    /// symbols where it doesn't.
    @ViewBuilder
    private var actions: some View {
        if isWorking {
            ProgressView().controlSize(.mini)
        }
        if !tray.items.isEmpty {
            ViewThatFits(in: .horizontal) {
                actionButtons(spelledOut: true)
                actionButtons(spelledOut: false)
            }
        }
    }

    private func actionButtons(spelledOut: Bool) -> some View {
        HStack(spacing: 6) {
            OrbitButton(title: spelledOut ? "AirDrop all" : nil, symbol: spelledOut ? nil : "dot.radiowaves.left.and.right",
                        help: "AirDrop everything") {
                FileActions.airDrop(tray.urls)
            }
            ShareLink(items: tray.urls) {
                TrayHeaderButtonLabel(symbol: "square.and.arrow.up")
            }
            .buttonStyle(PressableButtonStyle(scale: 0.96))
            .help("Share everything")
            .accessibilityLabel("Share everything")
            OrbitButton(symbol: "doc.zipper", help: "Compress everything") {
                isWorking = true
                Task {
                    if let archive = await FileActions.compress(tray.urls) { tray.add([archive]) }
                    isWorking = false
                }
            }
            if tray.items.contains(where: { !$0.isPinned }) {
                OrbitButton(title: "Clear", style: .ghost, help: "Clear the tray, all but what's pinned") { tray.clear() }
            }
        }
        .fixedSize()
    }
}

/// A band button's face for a control that isn't a plain button, like Share's link.
private struct TrayHeaderButtonLabel: View {
    let symbol: String
    @Environment(\.notchTheme) private var theme
    @ViewState private var hovering = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(theme.primary)
            .frame(width: NotchTheme.headerControlHeight, height: NotchTheme.headerControlHeight)
            .background(theme.controlShape.fill(hovering ? theme.controlHover : theme.hover))
            .contentShape(theme.controlShape)
            .onHover { hovering = $0 }
            .animation(.notchHighlight, value: hovering)
    }
}

/// What a snapshot draws as under the pointer, since a render has no pointer. Reset before every scene.
@MainActor
enum TraySnapshot {
    /// The file tile at this index shows its hover buttons.
    static var hoveredFile: Int?
    /// The clip row at this index shows its actions.
    static var hoveredClip: Int?
}

/// What the Tray knows about a file without opening it.
/// What a Tray file is. `TrayStore` reads it off the main thread and keeps it on the item, since a
/// tile draws it many times a second and the file can be on a disk that has gone away.
struct TrayFileInfo: Equatable, Sendable {
    var exists: Bool
    var isFolder = false
    var isPackage = false
    var fileSize: Int64?

    init(exists: Bool, isFolder: Bool = false, isPackage: Bool = false, fileSize: Int64? = nil) {
        self.exists = exists
        self.isFolder = isFolder
        self.isPackage = isPackage
        self.fileSize = fileSize
    }

    /// Reads the disk, so never on the main thread but for a snapshot's samples.
    init(reading url: URL) {
        exists = FileManager.default.fileExists(atPath: url.path)
        // A URL keeps the values it was asked for, and these are read again when the Tray reopens.
        let url = URL(fileURLWithPath: url.path)
        guard exists, let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .fileSizeKey]) else { return }
        isFolder = values.isDirectory == true
        isPackage = values.isPackage == true
        fileSize = values.fileSize.map(Int64.init)
    }

    /// Its size in bytes; nothing for a folder or a package, whose size would take a walk through it.
    var bytes: Int64? {
        isPackage || isFolder ? nil : fileSize
    }

    /// The file's size, or that it's a folder.
    var detail: String? {
        if isPackage { return nil }
        if isFolder { return "Folder" }
        return fileSize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
    }

    /// Came by itself, a screenshot or a download, in the last ten minutes.
    static func isNew(_ item: TrayStore.Item, now: Date) -> Bool {
        item.isAutomatic && now.timeIntervalSince(item.addedAt) < 10 * 60
    }
}

/// The strip under the tiles: drop files on it, or click to pick some. Alone in an empty tray it
/// takes all the room. A dashed outline at rest, the accent's solid face while files are over it.
private struct AddFilesStrip: View {
    let isTargeted: Bool
    let isAlone: Bool
    @Environment(\.notchTheme) private var theme
    @ViewState private var hovering = false

    var body: some View {
        let shape = theme.controlShape
        Button {
            let urls = FileActions.chooseFiles(prompt: "Add to Tray")
            if !urls.isEmpty { TrayStore.shared.add(urls) }
        } label: {
            let stack = isAlone ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 8))
            stack {
                Image(systemName: isTargeted ? "tray.and.arrow.down.fill" : "plus")
                    .font(.system(size: isAlone ? 13 : 11, weight: .bold))
                    .foregroundStyle(isTargeted ? theme.onAccent : theme.primary)
                    .frame(width: isAlone ? 30 : 22, height: isAlone ? 30 : 22)
                    .background(shape.fill(isTargeted ? theme.onAccent.opacity(0.16) : theme.hover))
                Text(message)
                    .font(isAlone ? NotchFont.body : NotchFont.subheadline)
                    .foregroundStyle(isTargeted ? theme.onAccent : hovering ? theme.primary : theme.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(isAlone ? 2 : 1)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                if isTargeted {
                    shape.fill(theme.accent)
                } else {
                    shape.fill(hovering ? theme.hover : .clear)
                    shape.strokeBorder(theme.tertiary.opacity(hovering ? 0.8 : 0.55), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(PressableButtonStyle(scale: 0.98))
        .onHover { hovering = $0 }
        .animation(.notchHighlight, value: hovering)
        .help("Add files to the Tray")
        // VoiceOver reads it last, after every file.
        .accessibilitySortPriority(-1)
    }

    private var message: String {
        if isTargeted { return "Let go to keep them in the Tray" }
        return isAlone ? "Drop files here to keep them handy, or click to add some"
                       : "Drop or click to add files · Space to Quick Look"
    }
}

/// A file as a tile: its thumbnail on a square of the panel's hover shade, its name and size under
/// it. The pointer brings up Quick Look, Share and Remove over the thumbnail and rings the tile in
/// the accent; the selected file, the one Space previews, keeps a thicker ring and a check.
private struct TrayTile: View {
    static let minimumWidth: CGFloat = 100
    static let thumbnailHeight: CGFloat = 70
    static let height: CGFloat = thumbnailHeight + 44

    let item: TrayStore.Item
    let isSelected: Bool
    let isNew: Bool
    /// Drawn as under the pointer, for snapshots.
    var forcesHover = false
    let viewModel: NotchViewModel
    @ObservedObject private var thumbnails = ThumbnailCache.shared
    @Environment(\.notchTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState private var isPointedAt = false

    private var hovering: Bool { isPointedAt || forcesHover }

    var body: some View {
        let shape = theme.controlShape
        VStack(spacing: 0) {
            thumbnail
            VStack(alignment: .leading, spacing: 2) {
                Text(item.url.lastPathComponent)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(theme.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(sizeLine)
                    .font(NotchFont.time(11, .medium))
                    .foregroundStyle(theme.secondary)
                    .lineLimit(1)
            }
            .padding(EdgeInsets(top: 7, leading: 9, bottom: 8, trailing: 9))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: Self.height)
        .background(theme.raised)
        .clipShape(shape)
        .overlay {
            if isSelected {
                shape.strokeBorder(theme.accent, lineWidth: 2)
            } else if hovering {
                shape.strokeBorder(theme.accent, lineWidth: 1.5)
            } else {
                shape.strokeBorder(theme.line, lineWidth: 1)
            }
        }
        .overlay(alignment: .topLeading) { badges }
        .contentShape(shape)
        .onHover { isPointedAt = $0 }
        .animation(.notchHighlight, value: hovering)
        .onTapGesture(count: 2) { FileActions.open(item.url) }
        .simultaneousGesture(TapGesture().onEnded {
            TrayStore.shared.select(item)
            TrayQuickLook.shared.takeKeyboard()
        })
        .onDrag {
            viewModel.isDraggingOut = true
            return NSItemProvider(contentsOf: item.url) ?? NSItemProvider()
        }
        .contextMenu { TrayItemMenu(item: item) }
        .help(item.url.path)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.url.lastPathComponent)
        .accessibilityValue([item.info?.detail, item.isPinned ? "Pinned" : nil, isNew ? "New" : nil]
            .compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction(named: "Quick Look", quickLook)
        .accessibilityAction(named: item.isPinned ? "Unpin" : "Pin") { TrayStore.shared.togglePin(item) }
        .accessibilityAction(named: "Remove from tray") { TrayStore.shared.remove(item) }
    }

    /// "2.1 MB", "Folder". A pin on the thumbnail says it's pinned.
    private var sizeLine: String {
        item.info?.detail ?? " "
    }

    private var thumbnail: some View {
        ZStack {
            theme.hover
            Image(nsImage: thumbnails.image(for: item.url))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 64, maxHeight: Self.thumbnailHeight - 16)
            if hovering {
                theme.background.opacity(0.6)
                HStack(spacing: 4) {
                    TileButton(symbol: "eye", help: "Quick Look", action: quickLook)
                    ShareLink(item: item.url) {
                        TileButtonLabel(symbol: "square.and.arrow.up")
                    }
                    .buttonStyle(PressableButtonStyle())
                    .help("Share")
                    .accessibilityLabel("Share")
                    TileButton(symbol: "xmark", help: "Remove from tray") { TrayStore.shared.remove(item) }
                }
                .transition(reduceMotion ? AnyTransition.opacity : .scale(scale: 0.85).combined(with: .opacity))
            }
        }
        .frame(height: Self.thumbnailHeight)
        .frame(maxWidth: .infinity)
        .clipped()
    }

    @ViewBuilder
    private var badges: some View {
        HStack(spacing: 4) {
            if isNew {
                Text("New")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(theme.onAccent)
                    .padding(.horizontal, 5)
                    .frame(height: 16)
                    .background(theme.controlShape.fill(theme.accent))
                    .accessibilityHidden(true)
            }
            if item.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(theme.accentText)
                    .frame(width: 16, height: 16)
                    .background(theme.controlShape.fill(theme.raised))
                    .help("Pinned: stays in the Tray")
                    .accessibilityHidden(true)
            }
            Spacer(minLength: 0)
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 8.5, weight: .heavy))
                    .foregroundStyle(theme.onAccent)
                    .frame(width: 16, height: 16)
                    .background(theme.controlShape.fill(theme.accent))
                    .accessibilityHidden(true)
            }
        }
        .padding(6)
    }

    private func quickLook() {
        TrayStore.shared.select(item)
        TrayQuickLook.shared.open()
    }
}

/// A button on a tile's thumbnail: Quick Look, Remove.
private struct TileButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            TileButtonLabel(symbol: symbol)
        }
        .buttonStyle(PressableButtonStyle())
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct TileButtonLabel: View {
    let symbol: String
    @Environment(\.notchTheme) private var theme
    @ViewState private var hovering = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(theme.primary)
            .frame(width: 26, height: 26)
            .background(theme.controlShape.fill(hovering ? theme.controlHover : theme.raised))
            .overlay(theme.controlShape.strokeBorder(theme.line))
            .contentShape(theme.controlShape)
            .onHover { hovering = $0 }
    }
}

private struct TrayItemMenu: View {
    let item: TrayStore.Item

    var body: some View {
        Button("Quick Look") {
            TrayStore.shared.select(item)
            TrayQuickLook.shared.open()
        }
        Button("Open") { FileActions.open(item.url) }
        Menu("Open With") {
            ForEach(FileActions.applications(for: item.url).prefix(15), id: \.self) { app in
                Button(FileManager.default.displayName(atPath: app.path)) { FileActions.open([item.url], with: app) }
            }
        }
        Button("Show in Finder") { FileActions.reveal([item.url]) }
        Button("Copy") { FileActions.copyToPasteboard([item.url]) }
        Divider()
        Button("AirDrop") { FileActions.airDrop([item.url]) }
        ShareLink(item: item.url) { Text("Share…") }
        Divider()
        Button("Compress") {
            Task { if let archive = await FileActions.compress([item.url]) { TrayStore.shared.add([archive]) } }
        }
        if FileActions.isArchive(item.url) {
            Button("Extract") {
                Task { if let folder = await FileActions.extract(item.url) { TrayStore.shared.add([folder]) } }
            }
        }
        if OnDeviceText.isAvailable, FileActions.isText(item.url) {
            TranslateMenu(text: { await FileActions.text(of: item.url) })
        }
        if FileActions.isImage(item.url) {
            Button("Copy Text") {
                Task { await ImageActions.copyText(from: [item.url]) }
            }
            Button("Cut Out") {
                Task { await ImageActions.cutOut([item.url]) }
            }
            Menu("Convert Image") {
                ForEach(FileActions.ImageFormat.allCases) { format in
                    Button("To \(format.title)") {
                        Task { if let output = await FileActions.convert(item.url, to: format) { TrayStore.shared.add([output]) } }
                    }
                }
                Divider()
                Button("Make Smaller (JPEG)") {
                    Task {
                        if let output = await FileActions.convert(item.url, to: .jpeg, quality: 0.72, maxPixelSize: 1600) {
                            TrayStore.shared.add([output])
                        }
                    }
                }
            }
        }
        Divider()
        Button("Copy to…") {
            if let folder = FileActions.chooseFolder(prompt: "Copy Here") {
                _ = FileActions.transfer([item.url], to: folder, move: false)
            }
        }
        Button("Move to…") {
            if let folder = FileActions.chooseFolder(prompt: "Move Here"),
               let moved = FileActions.transfer([item.url], to: folder, move: true).first {
                TrayStore.shared.relocate(item, to: moved)
            }
        }
        Divider()
        Button(item.isPinned ? "Unpin" : "Pin") { TrayStore.shared.togglePin(item) }
        Button("Remove from Tray") { TrayStore.shared.remove(item) }
    }
}

/// What the notch shows while files are being dragged toward it.
private struct TrayDropZones: View {
    @ObservedObject var viewModel: NotchViewModel

    var body: some View {
        // Six zones still fit the smallest notch, with a little less between them and fewer words.
        let hasImages = viewModel.isDraggingImages
        HStack(spacing: hasImages ? 6 : NotchTheme.gap) {
            DropZone(title: "Keep in Tray", subtitle: hasImages ? "Stash for later" : "Stash them for later", symbol: "tray.and.arrow.down",
                     isWide: true, viewModel: viewModel) { urls in
                TrayStore.shared.add(urls)
            }
            DropZone(title: "AirDrop", subtitle: "Send nearby", symbol: "dot.radiowaves.left.and.right", viewModel: viewModel) { urls in
                FileActions.airDrop(urls)
            }
            DropZone(title: "Compress", subtitle: "Make a .zip", symbol: "doc.zipper", viewModel: viewModel) { urls in
                if let archive = await FileActions.compress(urls) { TrayStore.shared.add([archive]) }
            }
            DropZone(title: "Copy to…", subtitle: "Pick a folder", symbol: "folder.badge.plus", viewModel: viewModel) { urls in
                if let folder = FileActions.chooseFolder(prompt: "Copy Here") {
                    _ = FileActions.transfer(urls, to: folder, move: false)
                }
            }
            if hasImages {
                DropZone(title: "Copy Text", subtitle: "Read the image", symbol: "text.viewfinder", viewModel: viewModel) { urls in
                    await ImageActions.copyText(from: urls)
                    TrayStore.shared.removeLeftovers(of: urls)
                }
                DropZone(title: "Cut Out", subtitle: "Lift the subject", symbol: "scissors", viewModel: viewModel) { urls in
                    await ImageActions.cutOut(urls)
                    TrayStore.shared.removeLeftovers(of: urls)
                }
            }
        }
    }
}

/// A place to drop the files: a card with a dashed outline, a glyph, a name and what it does.
/// Under the files it turns into the accent's solid face and rises to meet them.
private struct DropZone: View {
    let title: String
    var subtitle: String?
    let symbol: String
    var isWide = false
    let viewModel: NotchViewModel
    let perform: @MainActor ([URL]) async -> Void
    @Environment(\.notchTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState private var isTargeted = false

    init(title: String, subtitle: String? = nil, symbol: String, isWide: Bool = false,
         viewModel: NotchViewModel, perform: @escaping @MainActor ([URL]) async -> Void) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.isWide = isWide
        self.viewModel = viewModel
        self.perform = perform
    }

    var body: some View {
        let shape = theme.cardShape
        VStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(isTargeted ? theme.onAccent : theme.primary)
                .frame(width: 36, height: 36)
                .background(theme.controlShape.fill(isTargeted ? theme.onAccent.opacity(0.16) : theme.hover))
                .symbolEffect(.bounce, value: isTargeted)
                .padding(.bottom, 3)
            // The narrowest zone holds these with a point or so to spare, and a font that runs a
            // little wider on another macOS should shrink to fit rather than lose its last letters.
            Text(title)
                .font(NotchFont.headline)
                .foregroundStyle(isTargeted ? theme.onAccent : theme.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.9)
            if let subtitle {
                Text(subtitle)
                    .font(NotchFont.caption)
                    .foregroundStyle(isTargeted ? theme.onAccent : theme.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
            }
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: isWide ? .infinity : 124, maxHeight: .infinity)
        .background {
            if isTargeted {
                shape.fill(theme.accent)
            } else {
                shape.fill(theme.raised)
                shape.strokeBorder(theme.line, lineWidth: 1)
                shape.inset(by: 5).strokeBorder(theme.tertiary.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            }
        }
        .animation(.notchToggle, value: isTargeted)
        // With Reduce Motion it doesn't rise; it just takes the accent.
        .scaleEffect(isTargeted && !reduceMotion ? 1.03 : 1)
        .animation(.notchLift(reduceMotion: reduceMotion), value: isTargeted)
        .accessibilityElement(children: .combine)
        .trayDropTarget(isTargeted: $isTargeted) { providers in
            let viewModel = viewModel
            let perform = perform
            Task { @MainActor in
                let urls = await TrayDrop.urls(from: providers)
                viewModel.tab = .tray
                viewModel.traySide = .files
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { viewModel.isDraggingFiles = false }
                if !urls.isEmpty { await perform(urls) }
            }
            return true
        }
    }
}
