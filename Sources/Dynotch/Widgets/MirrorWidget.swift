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

    private init() {}

    func start() {
        status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor in
                    self.status = AVCaptureDevice.authorizationStatus(for: .video)
                    if granted { self.start() }
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
    @ViewState private var hovering = false

    var body: some View {
        ZStack {
            if camera.isRunning {
                CameraPreview(session: camera.session)
                    .transition(.opacity)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "person.crop.square")
                        .font(.system(size: 26, weight: .regular))
                    Text("Mirror")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Check yourself before a call")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.notchTertiary)
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(Color.white.opacity(hovering ? 0.95 : 0.7))
                .padding(8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.notchCard)
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                camera.isRunning ? camera.stop() : camera.start()
            }
        }
        .onHover { hovering = $0 }
        .onDisappear { camera.stop() }
        .help(camera.isRunning ? "Turn the mirror off" : "Turn the mirror on")
    }
}

private struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        return view
    }

    func updateNSView(_ nsView: PreviewView, context: Context) {}

    final class PreviewView: NSView {
        let previewLayer = AVCaptureVideoPreviewLayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer = CALayer()
            previewLayer.videoGravity = .resizeAspectFill
            // A mirror shows you flipped, the way you see yourself.
            previewLayer.setAffineTransform(CGAffineTransform(scaleX: -1, y: 1))
            layer?.addSublayer(previewLayer)
        }

        required init?(coder: NSCoder) { nil }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            previewLayer.frame = bounds
            CATransaction.commit()
        }
    }
}
