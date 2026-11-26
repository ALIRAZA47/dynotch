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
/// notch's meter is out of sight. A flat dark veil over the cover, in Orbit's dark ink whatever the
/// panel's light or dark, as it sits on the art.
struct ArtworkVolumeOverlay: View {
    var cornerRadius: CGFloat
    @ObservedObject private var volume = VolumeMonitor.shared

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let ink = NotchTheme.standard
        ZStack {
            if volume.isChanging {
                shape.fill(ink.background.opacity(0.84))
                VStack(spacing: 9) {
                    Image(systemName: volume.symbol)
                        .font(.system(size: 21, weight: .semibold))
                        .contentTransition(.symbolEffect(.replace))
                        .frame(height: 26)
                    LevelBar(level: volume.isMuted ? 0 : Double(volume.volume), color: ink.primary)
                        .frame(width: 50, height: 5)
                }
                .foregroundStyle(ink.primary)
            }
        }
        .animation(.easeOut(duration: 0.18), value: volume.isChanging)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
