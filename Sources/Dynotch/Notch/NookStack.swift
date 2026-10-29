import AppKit
import Combine
import SwiftUI

/// The widgets beside the player, one at a time like a stack of cards. It turns by itself to
/// whichever matters now: the calendar shortly before an event, the weather before rain, the
/// batteries when one runs low. A swipe up or down over it turns it by hand, and so do the dots on
/// its edge.
struct NookStack: View {
    let widgets: [HomeWidget]
    /// Swipes over the stack, from the window controller: true for the next card.
    let turns: PassthroughSubject<Bool, Never>
    @ObservedObject private var calendar = CalendarService.shared
    @ObservedObject private var weather = WeatherService.shared
    @ObservedObject private var power = PowerMonitor.shared
    @ObservedObject private var devices = DeviceBatteryMonitor.shared
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Turned to by hand, or by something that needed the room. Stays until the next turn.
    @ViewState private var picked: HomeWidget?
    /// The last turn went to a later card, so the new one comes up from below.
    @ViewState private var forward = true

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let urgent = urgentWidget(at: context.date)
            let shown = picked.flatMap { widgets.contains($0) ? $0 : nil } ?? urgent ?? widgets[0]
            HomeWidgetView(widget: shown)
                .id(shown)
                // With Reduce Motion the new card only fades in; it doesn't slide.
                .transition(.asymmetric(insertion: reduceMotion ? .opacity : .opacity.combined(with: .offset(y: forward ? 12 : -12)),
                                        removal: .opacity.animation(.easeOut(duration: 0.1))))
                .overlay(alignment: .trailing) {
                    // Centered in the card's trailing padding, so the dots never touch what's in the card.
                    if widgets.count > 1 {
                        pager(shown: shown)
                    }
                }
                .onChange(of: urgent) { _, widget in
                    guard let widget else { return }
                    turn(to: widget, from: shown)
                }
                .onReceive(turns) { next in
                    guard let index = widgets.firstIndex(of: shown) else { return }
                    let target = index + (next ? 1 : -1)
                    guard widgets.indices.contains(target) else { return }
                    Haptics.tap()
                    turn(to: widgets[target], from: shown)
                }
        }
        .background {
            if widgets.count > 1, !isSnapshot { StackSwipeArea() }
        }
    }

    private func turn(to widget: HomeWidget, from shown: HomeWidget) {
        forward = (widgets.firstIndex(of: widget) ?? 0) >= (widgets.firstIndex(of: shown) ?? 0)
        withAnimation(.notchTab) { picked = widget }
    }

    /// One dot a widget; the one showing is longer.
    private func pager(shown: HomeWidget) -> some View {
        VStack(spacing: 0) {
            ForEach(widgets, id: \.self) { widget in
                let isShown = widget == shown
                Button {
                    turn(to: widget, from: shown)
                } label: {
                    Capsule()
                        .fill(Color.white.opacity(isShown ? 0.75 : 0.25))
                        .frame(width: 4, height: isShown ? 12 : 4)
                        .frame(width: 12, height: isShown ? 18 : 10)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableButtonStyle(scale: 0.8))
                .help(widget.title)
                .accessibilityLabel(widget.title)
                .accessibilityAddTraits(isShown ? .isSelected : [])
            }
        }
    }

    /// The first widget in the stack with something that can't wait.
    private func urgentWidget(at now: Date) -> HomeWidget? {
        widgets.first { widget in
            switch widget {
            case .calendar:
                calendar.hasEventAccess && calendar.events(on: now).contains { event in
                    !event.isAllDay && event.end > now && event.start.timeIntervalSince(now) < 15 * 60
                }
            case .weather:
                weather.conditions.map { $0.isRaining || ($0.rainStart.map { $0.timeIntervalSince(now) < 30 * 60 } ?? false) } ?? false
            case .devices:
                (power.hasBattery && !power.isCharging && power.level <= 20)
                    || devices.devices.contains { ($0.lowest ?? 100) <= 20 }
            default:
                false
            }
        }
    }
}

/// Marks where the stack is, so the window controller turns it when a vertical swipe lands there.
private struct StackSwipeArea: NSViewRepresentable {
    func makeNSView(context: Context) -> StackSwipeAreaView { StackSwipeAreaView() }
    func updateNSView(_ view: StackSwipeAreaView, context: Context) {}
}

/// Takes no events: it's only there to be found.
final class StackSwipeAreaView: NSView {
    private static let all = NSHashTable<StackSwipeAreaView>.weakObjects()

    override init(frame: NSRect) {
        super.init(frame: frame)
        Self.all.add(self)
    }

    required init?(coder: NSCoder) { nil }

    /// A stack is on screen at `point` in `window`.
    static func covers(_ point: CGPoint, in window: NSWindow) -> Bool {
        all.allObjects.contains { view in
            view.window === window && !view.isHiddenOrHasHiddenAncestor
                && window.convertToScreen(view.convert(view.bounds, to: nil)).contains(point)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
