import AppKit
import SwiftUI

/// Scrolling over the view this covers changes the volume: fingers up for louder. Clicks go through
/// to whatever is underneath. Left out of snapshots, which can't draw AppKit views.
struct VolumeScrollArea: View {
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        if !isSnapshot {
            Representable()
        }
    }

    private struct Representable: NSViewRepresentable {
        func makeNSView(context: Context) -> VolumeScrollView { VolumeScrollView() }
        func updateNSView(_ view: VolumeScrollView, context: Context) {}
    }
}

/// Takes scroll-wheel events and nothing else.
final class VolumeScrollView: NSView {
    private static let all = NSHashTable<VolumeScrollView>.weakObjects()

    override init(frame: NSRect) {
        super.init(frame: frame)
        Self.all.add(self)
    }

    required init?(coder: NSCoder) { nil }

    /// One of these is on screen at `point` in `window`, so the notch leaves that scroll alone.
    static func covers(_ point: CGPoint, in window: NSWindow) -> Bool {
        all.allObjects.contains { view in
            view.window === window && !view.isHiddenOrHasHiddenAncestor
                && window.convertToScreen(view.convert(view.bounds, to: nil)).contains(point)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        NSApp.currentEvent?.type == .scrollWheel ? super.hitTest(point) : nil
    }

    override func scrollWheel(with event: NSEvent) {
        // Momentum would keep turning it up after the fingers have stopped.
        guard event.momentumPhase.isEmpty else { return }
        let fingersUp = event.isDirectionInvertedFromDevice ? -event.scrollingDeltaY : event.scrollingDeltaY
        // About a trackpad's height for the whole range; a wheel's notch is one volume-key step.
        let delta = event.hasPreciseScrollingDeltas ? fingersUp / 250 : fingersUp / 16
        VolumeMonitor.shared.nudge(by: Float(delta))
    }
}

/// The volume over the artwork for a moment after it changes. While the notch is open, the closed
/// notch's meter is out of sight.
struct ArtworkVolumeOverlay: View {
    var cornerRadius: CGFloat
    @ObservedObject private var volume = VolumeMonitor.shared

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            if volume.isChanging {
                shape
                    .fill(.ultraThinMaterial)
                    .overlay(shape.fill(Color.black.opacity(0.45)))
                    // The art's glass rim stays lit over the frosting, so the volume reads as the
                    // same pane of glass, frosted for a moment.
                    .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.4), .white.opacity(0.05)],
                                                               startPoint: .top, endPoint: .bottom), lineWidth: 1))
                VStack(spacing: 9) {
                    Image(systemName: volume.symbol)
                        .font(.system(size: 21, weight: .semibold))
                        .contentTransition(.symbolEffect(.replace))
                        .frame(height: 26)
                    LevelBar(level: volume.isMuted ? 0 : Double(volume.volume))
                        .frame(width: 50, height: 5)
                }
                .foregroundStyle(.white)
            }
        }
        .animation(.easeOut(duration: 0.18), value: volume.isChanging)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
