import AVKit
import SwiftUI

/// The output button in the player's title row, showing the current output. It swaps the player
/// for the list of outputs.
struct OutputButton: View {
    var tint: Color
    @ObservedObject private var outputs = AudioOutputs.shared
    @Environment(\.notchTheme) private var theme
    @ViewState private var hovering = false

    var body: some View {
        Button {
            if !outputs.isPickerShown { outputs.reload() }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) { outputs.isPickerShown.toggle() }
        } label: {
            Image(systemName: outputs.current?.symbol ?? "hifispeaker.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(outputs.isPickerShown ? tint : hovering ? theme.primary : theme.tertiary)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(PressableButtonStyle())
        .onHover { hovering = $0 }
        .animation(.notchHighlight, value: hovering)
        .help(outputs.current.map { "Playing through \($0.name)" } ?? "Choose an output")
        .accessibilityLabel("Output")
        .accessibilityValue(outputs.current?.name ?? "")
    }
}

/// The outputs, in place of the player: pick one to play through it. AirPlay speakers and TVs come
/// from AVKit's route picker in the header.
struct OutputPicker: View {
    var tint: Color
    @ObservedObject private var outputs = AudioOutputs.shared

    var body: some View {
        WidgetCard(title: "Output", symbol: "hifispeaker.fill") {
            HStack(spacing: 6) {
                AirPlayButton(tint: tint)
                CloseButton(action: close)
            }
        } content: {
            if outputs.devices.isEmpty {
                EmptyState(symbol: "speaker.slash", message: "No outputs found.")
            } else {
                Scroller(.vertical, fadesOverflow: true) {
                    VStack(spacing: 2) {
                        ForEach(outputs.devices) { device in
                            OutputRow(device: device, isCurrent: device.id == outputs.currentID, tint: tint) {
                                choose(device)
                            }
                        }
                    }
                }
            }
        }
    }

    private func choose(_ device: AudioOutputs.Device) {
        outputs.select(device)
        Task {
            // Long enough to see the check mark move.
            try? await Task.sleep(for: .milliseconds(350))
            close()
        }
    }

    private func close() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) { outputs.isPickerShown = false }
    }
}

private struct OutputRow: View {
    let device: AudioOutputs.Device
    let isCurrent: Bool
    let tint: Color
    let action: () -> Void
    @Environment(\.notchTheme) private var theme
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: device.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isCurrent ? tint : theme.secondary)
                    .frame(width: 18)
                Text(device.name)
                    .font(isCurrent ? NotchFont.bodyStrong : NotchFont.body)
                    .foregroundStyle(isCurrent ? theme.primary : theme.primary.opacity(0.85))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(device.name)
                if isCurrent {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(tint)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: theme.controlRadius, style: .continuous)
                .fill(isCurrent ? theme.controlHover : hovering ? theme.control : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle(scale: 0.98))
        .onHover { hovering = $0 }
        .animation(.notchHighlight, value: hovering)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}

/// Back to the player.
private struct CloseButton: View {
    let action: () -> Void
    @Environment(\.notchTheme) private var theme
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(hovering ? theme.primary : theme.secondary)
                .frame(width: 20, height: 20)
                .background(Circle().fill(hovering ? theme.controlHover : theme.control))
                .contentShape(Circle())
        }
        .buttonStyle(PressableButtonStyle())
        .onHover { hovering = $0 }
        .animation(.notchHighlight, value: hovering)
        .help("Back to the player")
        .accessibilityLabel("Back to the player")
    }
}

/// AVKit's AirPlay button with a label; its device list opens in a popover under the notch.
private struct AirPlayButton: View {
    var tint: Color
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.notchTheme) private var theme
    @ViewState private var handle = RoutePickerHandle()
    @ViewState private var hovering = false

    var body: some View {
        HStack(spacing: 3) {
            Group {
                if isSnapshot {
                    Image(systemName: "airplayaudio")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.secondary)
                } else {
                    RoutePicker(handle: handle, tint: NSColor(tint))
                }
            }
            .frame(width: 20, height: 20)
            Text("AirPlay")
                .font(NotchFont.bodyStrong)
                .foregroundStyle(hovering ? theme.primary : theme.secondary)
        }
        .padding(.leading, 2)
        .padding(.trailing, 9)
        .frame(height: 20)
        .background(Capsule().fill(hovering ? theme.controlHover : theme.control))
        .contentShape(Capsule())
        .onTapGesture { handle.present() }
        .onHover { hovering = $0 }
        .animation(.notchHighlight, value: hovering)
        .help("Play through an AirPlay speaker or TV")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("AirPlay")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { handle.present() }
    }
}

/// Lets the label beside the route picker open its list too.
private final class RoutePickerHandle {
    weak var view: AVRoutePickerView?

    @MainActor
    func present() {
        _ = view?.accessibilityPerformPress()
    }
}

private struct RoutePicker: NSViewRepresentable {
    let handle: RoutePickerHandle
    let tint: NSColor

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.isRoutePickerButtonBordered = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateNSView(_ picker: AVRoutePickerView, context: Context) {
        picker.setRoutePickerButtonColor(NSColor.white.withAlphaComponent(0.58), for: .normal)
        picker.setRoutePickerButtonColor(.white, for: .normalHighlighted)
        picker.setRoutePickerButtonColor(tint, for: .active)
        picker.setRoutePickerButtonColor(tint, for: .activeHighlighted)
        handle.view = picker
    }

    static func dismantleNSView(_ picker: AVRoutePickerView, coordinator: Coordinator) {
        AudioOutputs.shared.isPresentingRoutes = false
    }

    /// Keeps the notch open while the route list is up, since it hangs below the notch.
    final class Coordinator: NSObject, AVRoutePickerViewDelegate {
        func routePickerViewWillBeginPresentingRoutes(_ routePickerView: AVRoutePickerView) {
            MainActor.assumeIsolated { AudioOutputs.shared.isPresentingRoutes = true }
        }

        func routePickerViewDidEndPresentingRoutes(_ routePickerView: AVRoutePickerView) {
            MainActor.assumeIsolated { AudioOutputs.shared.isPresentingRoutes = false }
        }
    }
}
