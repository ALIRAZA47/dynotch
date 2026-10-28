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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            toolbar
            // With room to spare, the last tile takes all of it, so an empty tray is one big place to
            // drop files. More files than fit scroll sideways.
            ViewThatFits(in: .horizontal) {
                strip
                Scroller(.horizontal) { strip }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .trayDropTarget(isTargeted: $isTargeted) { providers in
            Task { TrayStore.shared.add(await TrayDrop.urls(from: providers)) }
            return true
        }
        .animation(.notchHighlight, value: isTargeted)
        .background {
            if !isSnapshot { QuickLookAnchor(viewModel: viewModel) }
        }
    }

    /// The files, then the tile that adds more.
    private var strip: some View {
        HStack(spacing: 6) {
            ForEach(tray.items) { item in
                TrayItemView(item: item, isSelected: tray.selection == item.id, viewModel: viewModel)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
            AddFilesTile(isTargeted: isTargeted, isAlone: tray.items.isEmpty)
        }
        .frame(maxHeight: .infinity)
    }

    /// What's in the tray, and AirDrop, Share and Clear for all of it.
    private var toolbar: some View {
        HStack(spacing: 2) {
            HStack(spacing: 6) {
                Text("Files")
                    .font(NotchFont.bodyStrong)
                if !tray.items.isEmpty {
                    Text("\(tray.items.count)")
                        .font(NotchFont.numeric(10.5))
                        .foregroundStyle(theme.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.control))
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

private struct ToolbarButtonLabel: View {
    let symbol: String
    @Environment(\.notchTheme) private var theme
    @ViewState private var hovering = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(hovering ? theme.primary : theme.secondary)
            .frame(width: 28, height: 24)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? theme.control : .clear))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(.notchHighlight, value: hovering)
    }
}

/// The last tile: drop files on the tray, or click to pick some. It takes whatever room the files
/// leave, all of it in an empty tray.
private struct AddFilesTile: View {
    let isTargeted: Bool
    let isAlone: Bool
    @Environment(\.notchTheme) private var theme
    @ViewState private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: theme.cardRadius - 2, style: .continuous)
        Button {
            let urls = FileActions.chooseFiles(prompt: "Add to Tray")
            if !urls.isEmpty { TrayStore.shared.add(urls) }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: isTargeted ? "tray.and.arrow.down.fill" : "plus")
                    .font(.system(size: isAlone ? 18 : 15, weight: .medium))
                    .contentTransition(.symbolEffect(.replace))
                Text(isAlone ? "Drop files here to keep them handy, or click to add some" : "Drop or add files")
                    .font(NotchFont.caption)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(isTargeted ? theme.accent : hovering ? theme.secondary : theme.tertiary)
            .padding(.horizontal, 10)
            .frame(minWidth: 100, maxWidth: .infinity, maxHeight: .infinity)
            .background(shape.fill(isTargeted ? theme.selectionFill : hovering ? theme.card : .clear))
            .overlay(shape.strokeBorder(isTargeted ? theme.accent : theme.primary.opacity(hovering ? 0.24 : 0.16),
                                        style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
            .contentShape(shape)
        }
        .buttonStyle(PressableButtonStyle(scale: 0.97))
        .onHover { hovering = $0 }
        .animation(.notchHighlight, value: hovering)
        .help("Add files to the Tray")
    }
}

private struct TrayItemView: View {
    let item: TrayStore.Item
    /// Selected like a file in Finder: the space bar previews it.
    let isSelected: Bool
    let viewModel: NotchViewModel
    @ObservedObject private var thumbnails = ThumbnailCache.shared
    @Environment(\.notchTheme) private var theme
    @ViewState private var hovering = false

    @ViewState private var detail: String?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: theme.cardRadius - 2, style: .continuous)
        VStack(spacing: 5) {
            Image(nsImage: thumbnails.image(for: item.url))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 56, height: 50)
                .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
            Text(item.url.lastPathComponent)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.primary.opacity(0.92))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(width: 88, height: 28, alignment: .top)
            Text(detail ?? " ")
                .font(NotchFont.numeric(10, .medium))
                .foregroundStyle(theme.tertiary)
                .lineLimit(1)
        }
        .padding(.vertical, 6)
        .frame(width: 100)
        .background(shape.fill(isSelected ? theme.selectionFill : hovering ? theme.control : .clear))
        .overlay(shape.strokeBorder(isSelected ? theme.selectionRing : .clear, lineWidth: 1.5))
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
                .transition(.scale(scale: 0.6).combined(with: .opacity))
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
}

extension TrayItemView {
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

private struct DropZone: View {
    let title: String
    var subtitle: String?
    let symbol: String
    var isWide = false
    let viewModel: NotchViewModel
    let perform: @MainActor ([URL]) async -> Void
    @Environment(\.notchTheme) private var theme
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
        let shape = RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous)
        VStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(isTargeted ? theme.accent : theme.primary.opacity(0.85))
                .symbolEffect(.bounce, value: isTargeted)
                .frame(height: 28)
                .padding(.bottom, 2)
            Text(title)
                .font(NotchFont.headline)
                .lineLimit(1)
            if let subtitle {
                Text(subtitle)
                    .font(NotchFont.caption)
                    .foregroundStyle(isTargeted ? theme.secondary : theme.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: isWide ? .infinity : 124, maxHeight: .infinity)
        .background(shape.fill(isTargeted ? theme.selectionFill : .clear))
        .overlay {
            if isTargeted {
                shape.strokeBorder(theme.accent, lineWidth: 1.5)
            } else {
                shape.strokeBorder(theme.primary.opacity(0.18), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
            }
        }
        .scaleEffect(isTargeted ? 1.03 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isTargeted)
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
