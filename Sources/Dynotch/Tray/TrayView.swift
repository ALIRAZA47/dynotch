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
        HStack(spacing: NotchTheme.gap) {
            VStack(alignment: .leading, spacing: NotchTheme.titleGap) {
                header
                if tray.items.isEmpty {
                    EmptyState(symbol: "tray.and.arrow.down", message: "Drop files here to keep them handy")
                } else {
                    Scroller(.horizontal) {
                        HStack(spacing: 4) {
                            ForEach(tray.items) { item in
                                TrayItemView(item: item, isSelected: tray.selection == item.id, viewModel: viewModel)
                                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                            }
                        }
                        // Centered in the room under the title.
                        .frame(maxHeight: .infinity)
                    }
                }
            }
            .padding(NotchTheme.cardPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(CardSurface(isHighlighted: isTargeted))
            .overlay(RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous)
                .strokeBorder(theme.primary.opacity(isTargeted ? 0.55 : 0), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
            .animation(.notchHighlight, value: isTargeted)
            .trayDropTarget(isTargeted: $isTargeted) { providers in
                Task { TrayStore.shared.add(await TrayDrop.urls(from: providers)) }
                return true
            }

            AirDropTile()
                .frame(width: 96)
        }
        .background {
            if !isSnapshot { QuickLookAnchor(viewModel: viewModel) }
        }
    }

    private var header: some View {
        CardTitle(title: "Tray", symbol: "tray.full.fill") {
            HStack(spacing: 2) {
                if isWorking {
                    ProgressView().controlSize(.mini)
                        .padding(.trailing, 4)
                }
                if !tray.items.isEmpty {
                    Text(tray.items.count == 1 ? "1 item" : "\(tray.items.count) items")
                        .font(NotchFont.caption)
                        .padding(.trailing, 6)
                    CardButton(symbol: "doc.zipper", help: "Compress everything") {
                        isWorking = true
                        Task {
                            if let archive = await FileActions.compress(tray.urls) { tray.add([archive]) }
                            isWorking = false
                        }
                    }
                    CardButton(symbol: "folder", help: "Show in Finder") { FileActions.reveal(tray.urls) }
                    CardButton(symbol: "trash", help: "Clear the tray") { tray.clear() }
                }
            }
        }
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

    var body: some View {
        VStack(spacing: 5) {
            Image(nsImage: thumbnails.image(for: item.url))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 46, height: 46)
                .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: theme.controlRadius, style: .continuous)
                    .fill(isSelected ? theme.controlHover : .clear))
            Text(item.url.lastPathComponent)
                .font(NotchFont.caption)
                .foregroundStyle(isSelected ? Color.white : theme.primary.opacity(0.9))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .truncationMode(.middle)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(isSelected ? theme.accent.opacity(0.55) : .clear))
                .frame(width: 78, height: 28, alignment: .top)
        }
        .padding(.top, 4)
        .frame(width: 80)
        .background(RoundedRectangle(cornerRadius: theme.controlRadius + 3, style: .continuous)
            .fill(hovering && !isSelected ? theme.control : .clear))
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

/// Drop files to AirDrop them; click to AirDrop everything in the tray.
private struct AirDropTile: View {
    @ObservedObject private var tray = TrayStore.shared
    @Environment(\.notchTheme) private var theme
    @ViewState private var isTargeted = false
    @ViewState private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous)
        Button {
            if !tray.items.isEmpty { FileActions.airDrop(tray.urls) }
        } label: {
            VStack(spacing: 8) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(isTargeted ? Color.blue : hovering ? theme.primary : theme.primary.opacity(0.8))
                    .symbolEffect(.bounce, value: isTargeted)
                Text("AirDrop")
                    .font(NotchFont.bodyStrong)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                if isTargeted {
                    shape.fill(Color.blue.opacity(0.25))
                } else {
                    CardSurface(isHighlighted: hovering)
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(PressableButtonStyle(scale: 0.97))
        .onHover { hovering = $0 }
        .animation(.notchHighlight, value: hovering)
        .help(tray.items.isEmpty ? "Drop files here to AirDrop them" : "AirDrop everything in the tray")
        .trayDropTarget(isTargeted: $isTargeted) { providers in
            Task {
                let urls = await TrayDrop.urls(from: providers)
                if !urls.isEmpty { FileActions.airDrop(urls) }
            }
            return true
        }
    }
}

/// What the notch shows while files are being dragged toward it.
private struct TrayDropZones: View {
    @ObservedObject var viewModel: NotchViewModel

    var body: some View {
        HStack(spacing: NotchTheme.gap) {
            DropZone(title: "Keep in Tray", subtitle: "Drop to stash for later", symbol: "tray.and.arrow.down.fill",
                     tint: .white, isWide: true, viewModel: viewModel) { urls in
                TrayStore.shared.add(urls)
            }
            DropZone(title: "AirDrop", symbol: "dot.radiowaves.left.and.right", tint: .blue, viewModel: viewModel) { urls in
                FileActions.airDrop(urls)
            }
            DropZone(title: "Compress", symbol: "doc.zipper", tint: .orange, viewModel: viewModel) { urls in
                if let archive = await FileActions.compress(urls) { TrayStore.shared.add([archive]) }
            }
            DropZone(title: "Copy to…", symbol: "folder.badge.plus", tint: .green, viewModel: viewModel) { urls in
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
    let tint: Color
    var isWide = false
    let viewModel: NotchViewModel
    let perform: @MainActor ([URL]) async -> Void
    @Environment(\.notchTheme) private var theme
    @ViewState private var isTargeted = false

    init(title: String, subtitle: String? = nil, symbol: String, tint: Color, isWide: Bool = false,
         viewModel: NotchViewModel, perform: @escaping @MainActor ([URL]) async -> Void) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.tint = tint
        self.isWide = isWide
        self.viewModel = viewModel
        self.perform = perform
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous)
        VStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: isWide ? 26 : 20, weight: .medium))
                .foregroundStyle(isTargeted ? tint : theme.primary.opacity(0.75))
                .symbolEffect(.bounce, value: isTargeted)
                .frame(height: 30)
            Text(title)
                .font(NotchFont.headline)
            if let subtitle {
                Text(subtitle)
                    .font(NotchFont.caption)
                    .foregroundStyle(theme.tertiary)
            }
        }
        .frame(maxWidth: isWide ? .infinity : 100, maxHeight: .infinity)
        .background(shape.fill(isTargeted ? tint.opacity(0.2) : theme.card))
        .overlay(shape.strokeBorder(isTargeted ? tint : theme.primary.opacity(0.2), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
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
