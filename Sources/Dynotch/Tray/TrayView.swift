import SwiftUI
import UniformTypeIdentifiers

/// The Tray tab: parked files, or drop zones while files are dragged in.
struct TrayTabView: View {
    @ObservedObject var viewModel: NotchViewModel

    var body: some View {
        if viewModel.isDraggingFiles {
            TrayDropZones(viewModel: viewModel)
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
        VStack(alignment: .leading, spacing: 10) {
            toolbar
            shelf
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
    }

    /// The files stand on a pane of glass, a shelf in the notch, and round off with `controlRadius`
    /// inside it, like the rows inside a card. A shelf too short for a whole file shows them compact.
    private var shelf: some View {
        GeometryReader { proxy in
            let fit = TrayItemView.Fit(height: proxy.size.height)
            // With room to spare, the last tile takes all of it, so an empty tray is one big place to
            // drop files. More files than fit scroll sideways, as far as the shelf's rim.
            ViewThatFits(in: .horizontal) {
                strip(fit)
                    .padding(.horizontal, theme.controlRadius)
                Scroller(.horizontal) {
                    strip(fit)
                        .padding(.horizontal, theme.controlRadius)
                }
            }
        }
        .padding(.vertical, theme.controlRadius)
        .clipShape(RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous).inset(by: 1))
        .background(CardSurface())
    }

    /// The files, then the tile that adds more.
    private func strip(_ fit: TrayItemView.Fit) -> some View {
        HStack(spacing: 6) {
            ForEach(tray.items) { item in
                TrayItemView(item: item, isSelected: tray.selection == item.id, viewModel: viewModel, fit: fit)
                    .transition(reduceMotion ? AnyTransition.opacity : .scale(scale: 0.6).combined(with: .opacity))
            }
            AddFilesTile(isTargeted: isTargeted, isAlone: tray.items.isEmpty)
        }
        // One group, so VoiceOver reads the Add tile after the files in a strip that scrolls, too.
        .accessibilityElement(children: .contain)
        .frame(maxHeight: .infinity)
    }

    /// What's in the tray, and AirDrop, Share and Clear for all of it.
    private var toolbar: some View {
        HStack(spacing: 2) {
            HStack(spacing: 6) {
                Text("Files")
                    .font(NotchFont.bodyStrong)
                    .foregroundStyle(theme.primary)
                if !tray.items.isEmpty {
                    // Secondary, like a count on a segment's thumb: in tertiary, on this glass over
                    // Liquid Glass, it reads under 4.5:1.
                    Text("\(tray.items.count)")
                        .font(NotchFont.numeric(10.5))
                        .foregroundStyle(theme.secondary)
                }
            }
            .padding(.horizontal, 11)
            .frame(height: 25)
            .glass(.control, in: Capsule())
            Spacer(minLength: 0)
            if isWorking {
                ProgressView().controlSize(.mini)
                    .padding(.trailing, 6)
            }
            if !tray.items.isEmpty {
                ToolbarButton(symbol: "dot.radiowaves.left.and.right", help: "AirDrop everything") {
                    FileActions.airDrop(tray.urls)
                }
                ShareLink(items: tray.urls) {
                    ToolbarButtonLabel(symbol: "square.and.arrow.up")
                }
                .buttonStyle(PressableButtonStyle())
                .help("Share everything")
                ToolbarButton(symbol: "doc.zipper", help: "Compress everything") {
                    isWorking = true
                    Task {
                        if let archive = await FileActions.compress(tray.urls) { tray.add([archive]) }
                        isWorking = false
                    }
                }
                ToolbarButton(symbol: "trash", help: "Clear the tray") { tray.clear() }
            }
        }
    }
}

/// A toolbar symbol button: AirDrop, Share, Clear.
private struct ToolbarButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ToolbarButtonLabel(symbol: symbol)
        }
        .buttonStyle(PressableButtonStyle())
        .help(help)
        .accessibilityLabel(help)
    }
}

/// A toolbar symbol; under the pointer a capsule of glass rises behind it.
private struct ToolbarButtonLabel: View {
    let symbol: String
    @Environment(\.notchTheme) private var theme
    @ViewState private var hovering = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(hovering ? theme.primary : theme.secondary)
            .frame(width: 28, height: 25)
            .background {
                if hovering { GlassSurface(depth: .control, shape: Capsule()) }
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(.notchHighlight, value: hovering)
    }
}

/// The last tile: drop files on the tray, or click to pick some. It takes whatever room the files
/// leave, all of it in an empty tray. A well in the shelf with a dashed rim and a + key, it turns
/// into the accent's jewel while files are over it.
private struct AddFilesTile: View {
    let isTargeted: Bool
    let isAlone: Bool
    @Environment(\.notchTheme) private var theme
    @ViewState private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: theme.controlRadius, style: .continuous)
        Button {
            let urls = FileActions.chooseFiles(prompt: "Add to Tray")
            if !urls.isEmpty { TrayStore.shared.add(urls) }
        } label: {
            VStack(spacing: 6) {
                DropKey(symbol: isTargeted ? "tray.and.arrow.down.fill" : "plus", side: isAlone ? 32 : 26,
                        glyph: .system(size: isAlone ? 13 : 11, weight: .bold), isOnLens: isTargeted, isLit: hovering)
                Text(isAlone ? "Drop files here to keep them handy, or click to add some" : "Drop or add files")
                    .font(NotchFont.caption)
                    .foregroundStyle(isTargeted ? theme.onAccent : hovering ? theme.secondary : theme.tertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 10)
            .frame(minWidth: 100, maxWidth: .infinity, maxHeight: .infinity)
            .background(DropWell(cornerRadius: theme.controlRadius, isTargeted: isTargeted, isLit: hovering))
            // One layer, so the notch's shadow falls behind the tile rather than from its ink onto its face.
            .compositingGroup()
            .contentShape(shape)
        }
        .buttonStyle(PressableButtonStyle(scale: 0.97))
        .onHover { hovering = $0 }
        .animation(.notchHighlight, value: hovering)
        .help("Add files to the Tray")
        // VoiceOver reads it last, after every file's size. A compact tile's size, read but not drawn,
        // sits below the tile, so going by position alone VoiceOver would read it after this one.
        .accessibilitySortPriority(-1)
    }
}

private struct TrayItemView: View {
    let item: TrayStore.Item
    /// Selected like a file in Finder: the space bar previews it.
    let isSelected: Bool
    let viewModel: NotchViewModel
    let fit: Fit
    @ObservedObject private var thumbnails = ThumbnailCache.shared
    @Environment(\.notchTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState private var hovering = false

    @ViewState private var detail: String?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: theme.controlRadius, style: .continuous)
        VStack(spacing: 5) {
            thumbnail
            name
            if !fit.isCompact { size }
        }
        // A compact tile has no room for the size, but VoiceOver reads it there as on a whole tile.
        .accessibilityRepresentation {
            VStack(spacing: 5) {
                thumbnail
                name
                size
            }
        }
        .padding(.vertical, 6)
        .frame(width: 100)
        // As tall as the Add tile beside it, so a pane or a selection doesn't float in a tall shelf.
        .frame(maxHeight: .infinity)
        .background {
            // A pane rises under the pointer. The selected file holds the accent's light inside a ring
            // of it, so the selection never rests on color alone.
            if isSelected {
                GlassSurface(depth: .tint(theme.accent), shape: shape, isLit: hovering)
                    .overlay(shape.strokeBorder(theme.accent.opacity(0.8), lineWidth: 1.5))
            } else if hovering {
                GlassSurface(depth: .pane, shape: shape)
            }
        }
        .task(id: item.url) { detail = await Self.detail(for: item.url) }
        .overlay(alignment: .topTrailing) {
            if hovering {
                Button { TrayStore.shared.remove(item) } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Color.black, Color.white.opacity(0.85))
                }
                .buttonStyle(PressableButtonStyle())
                .help("Remove from tray")
                .transition(reduceMotion ? AnyTransition.opacity : .scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
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
    }

    private var thumbnail: some View {
        Image(nsImage: thumbnails.image(for: item.url))
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 56, height: fit.thumbnailHeight)
            .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
    }

    private var name: some View {
        Text(item.url.lastPathComponent)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(theme.primary)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .truncationMode(.middle)
            .frame(width: 88, height: 28, alignment: .top)
    }

    /// The file's size, or that it's a folder. On the accent's light, tertiary reads under 4.5:1
    /// (yellow over Liquid Glass), so the size steps up to secondary there.
    private var size: some View {
        Text(detail ?? " ")
            .font(NotchFont.caption)
            .foregroundStyle(isSelected ? theme.secondary : theme.tertiary)
            .lineLimit(1)
    }
}

extension TrayItemView {
    /// How the files fit the shelf. A whole tile is 112 points tall; on a shorter shelf, as in the
    /// smallest notch, the thumbnail shrinks and the size goes, so every name still shows in full.
    struct Fit {
        let isCompact: Bool
        let thumbnailHeight: CGFloat

        init(height: CGFloat) {
            isCompact = height < 112
            // A compact tile is its thumbnail and 45 points more, 89 in all. The roundest corners pad
            // the smallest notch's shelf down to 85, so there the thumbnail gives up the difference
            // rather than the tile being cut off.
            thumbnailHeight = isCompact ? min(44, max(32, (height - 45).rounded(.down))) : 50
        }
    }

    /// The file's size, or that it's a folder, read off the main thread. Nothing for packages,
    /// whose size would take a walk through them.
    fileprivate static func detail(for url: URL) async -> String? {
        await Task.detached(priority: .utility) {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .fileSizeKey])
            if values?.isPackage == true { return nil }
            if values?.isDirectory == true { return "Folder" }
            return values?.fileSize.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
        }.value
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
        if FileActions.isImage(item.url) {
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
        Button("Remove from Tray") { TrayStore.shared.remove(item) }
    }
}

/// What the notch shows while files are being dragged toward it.
private struct TrayDropZones: View {
    @ObservedObject var viewModel: NotchViewModel

    var body: some View {
        HStack(spacing: 10) {
            DropZone(title: "Keep in Tray", subtitle: "Stash them for later", symbol: "tray.and.arrow.down",
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
        }
    }
}

/// A well to drop the files in, with a badge, a name and what it does. Under the files it turns into
/// the accent's jewel and rises to meet them.
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
        VStack(spacing: 5) {
            DropKey(symbol: symbol, side: 38, glyph: .system(size: 17, weight: .semibold), isOnLens: isTargeted)
                .symbolEffect(.bounce, value: isTargeted)
                .padding(.bottom, 2)
            Text(title)
                .font(NotchFont.headline)
                .foregroundStyle(isTargeted ? theme.onAccent : theme.primary)
                .lineLimit(1)
            if let subtitle {
                Text(subtitle)
                    .font(NotchFont.caption)
                    .foregroundStyle(isTargeted ? theme.onAccent.opacity(0.8) : theme.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: isWide ? .infinity : 124, maxHeight: .infinity)
        .background(DropWell(cornerRadius: theme.cardRadius, isTargeted: isTargeted))
        // One layer, so the notch's shadow falls behind the zone rather than from its ink onto its face.
        .compositingGroup()
        .animation(.notchToggle, value: isTargeted)
        // With Reduce Motion it doesn't rise; it just turns into the jewel.
        .scaleEffect(isTargeted && !reduceMotion ? 1.03 : 1)
        .animation(.notchLift(reduceMotion: reduceMotion), value: isTargeted)
        .trayDropTarget(isTargeted: $isTargeted) { providers in
            let viewModel = viewModel
            let perform = perform
            Task { @MainActor in
                let urls = await TrayDrop.urls(from: providers)
                viewModel.tab = .tray
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { viewModel.isDraggingFiles = false }
                if !urls.isEmpty { await perform(urls) }
            }
            return true
        }
    }
}

/// A place to drop files: a well pressed into the glass, ringed 4 points in by a dashed line lit from
/// above. While files are over it, it becomes the accent's jewel, its light spilling onto the glass.
private struct DropWell: View {
    let cornerRadius: CGFloat
    let isTargeted: Bool
    var isLit = false
    @Environment(\.notchTheme) private var theme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        // The dashes are brightest along the top, where the light falls, and come up with the pointer
        // or Increase Contrast.
        let top = (isLit ? 0.4 : 0.3) + (theme.isHighContrast ? 0.15 : 0)
        ZStack {
            GlassSurface(depth: .well, shape: shape, isLit: isLit)
            shape.inset(by: 4)
                .strokeBorder(LinearGradient(colors: [.white.opacity(top), .white.opacity(isLit ? 0.2 : 0.14)],
                                             startPoint: .top, endPoint: .bottom),
                              style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                .opacity(isTargeted ? 0 : 1)
            if isTargeted {
                GlassSurface(depth: .lens(theme.accent), shape: shape, spills: true)
                    .transition(.opacity)
            }
        }
    }
}

/// A disc of glass holding a symbol: the + key on the add tile, a drop zone's badge. On the accent's
/// jewel it's pressed into the face instead, in ink.
private struct DropKey: View {
    let symbol: String
    let side: CGFloat
    let glyph: Font
    var isOnLens = false
    var isLit = false
    @Environment(\.notchTheme) private var theme

    var body: some View {
        Image(systemName: symbol)
            .font(glyph)
            .foregroundStyle(isOnLens ? theme.onAccent : theme.primary)
            .contentTransition(.symbolEffect(.replace))
            .frame(width: side, height: side)
            .background {
                if isOnLens {
                    Circle().fill(theme.onAccent.opacity(0.12))
                        .overlay(Circle().strokeBorder(theme.onAccent.opacity(0.18)))
                } else {
                    GlassSurface(depth: .control, shape: Circle(), isLit: isLit)
                }
            }
    }
}
