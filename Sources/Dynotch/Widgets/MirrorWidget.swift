@preconcurrency import AVFoundation
import SwiftUI

/// The front camera, only while the mirror is on screen and switched on.
@MainActor
final class CameraService: ObservableObject {
    static let shared = CameraService()

    @Published private(set) var isRunning = false
    @Published private(set) var status = AVCaptureDevice.authorizationStatus(for: .video)

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "app.dynotch.camera")
    private var isConfigured = false
    /// The mirror asked for the camera and hasn't been turned off or left the screen since.
    private var isWanted = false

    private init() {}

    func start() {
        isWanted = true
        status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor in
                    self.status = AVCaptureDevice.authorizationStatus(for: .video)
                    // The prompt may outlive the mirror; the camera only starts for one that's still there.
                    if granted, self.isWanted { self.start() }
                }
            }
            return
        case .authorized:
            break
        default:
            CalendarService.openPrivacySettings("Privacy_Camera")
            return
        }
        guard !isRunning else { return }
        isRunning = true
        let session = session
        let needsSetup = !isConfigured
        isConfigured = true
        sessionQueue.async {
            if needsSetup {
                session.beginConfiguration()
                session.sessionPreset = .high
                if let device = AVCaptureDevice.default(for: .video),
                   let input = try? AVCaptureDeviceInput(device: device),
                   session.canAddInput(input) {
                    session.addInput(input)
                }
                session.commitConfiguration()
            }
            session.startRunning()
        }
    }

    func stop() {
        isWanted = false
        guard isRunning else { return }
        isRunning = false
        let session = session
        sessionQueue.async { session.stopRunning() }
    }

    /// Asks for camera access without turning the camera on.
    func requestAccess() {
        guard status == .notDetermined else {
            if status != .authorized { CalendarService.openPrivacySettings("Privacy_Camera") }
            return
        }
        AVCaptureDevice.requestAccess(for: .video) { _ in
            Task { @MainActor in self.status = AVCaptureDevice.authorizationStatus(for: .video) }
        }
    }
}

struct MirrorWidget: View {
    @ObservedObject private var camera = CameraService.shared
    @Environment(\.notchTheme) private var theme
    @ViewState private var hovering = false

    var body: some View {
        let shape = theme.cardShape
        ZStack {
            if camera.isRunning {
                // Set into the card like a picture in a frame, its corners following the buttons'.
                CameraPreview(session: camera.session, cornerRadius: theme.controlRadius)
                    .padding(NotchTheme.cardPadding)
                    .transition(.opacity)
            } else {
                VStack(spacing: 0) {
                    // Orbit's glyph square, a size up: the accent's wash under the pointer.
                    Image(systemName: "person.crop.square")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(hovering ? theme.accentText : theme.secondary)
                        .frame(width: 44, height: 44)
                        .background(theme.controlShape.fill(hovering ? theme.accentSoft : theme.hover))
                    Text("Mirror")
                        .font(NotchFont.headline)
                        .foregroundStyle(theme.primary)
                        .padding(.top, 10)
                    Text("Check yourself before a call")
                        .font(NotchFont.subheadline)
                        .foregroundStyle(theme.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
                .padding(12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CardSurface(isHighlighted: hovering && !camera.isRunning))
        .clipShape(shape)
        .contentShape(shape)
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                camera.isRunning ? camera.stop() : camera.start()
            }
        }
        .onHover { hovering = $0 }
        .animation(.notchHighlight, value: hovering)
        .onDisappear { camera.stop() }
        .help(camera.isRunning ? "Turn the mirror off" : "Turn the mirror on")
    }
}

private struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    /// The picture's corners. The layer rounds them itself, so the video can't spill past them.
    var cornerRadius: CGFloat = 0

    func makeNSView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.round(cornerRadius)
        return view
    }

    func updateNSView(_ nsView: PreviewView, context: Context) {
        nsView.round(cornerRadius)
    }

    final class PreviewView: NSView {
        let previewLayer = AVCaptureVideoPreviewLayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer = CALayer()
            layer?.masksToBounds = true
            layer?.cornerCurve = .continuous
            previewLayer.videoGravity = .resizeAspectFill
            // A mirror shows you flipped, the way you see yourself.
            previewLayer.setAffineTransform(CGAffineTransform(scaleX: -1, y: 1))
            layer?.addSublayer(previewLayer)
        }

        required init?(coder: NSCoder) { nil }

        func round(_ radius: CGFloat) {
            guard layer?.cornerRadius != radius else { return }
            layer?.cornerRadius = radius
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            previewLayer.frame = bounds
            CATransaction.commit()
        }
    }
}
