import AVKit
import SwiftUI

/// The output button in the player's title row, showing the current output. It swaps the player
/// for the list of outputs.
struct OutputButton: View {
    var tint: Color
    @ObservedObject private var outputs = AudioOutputs.shared
    @ViewState private var hovering = false

    var body: some View {
        Button {
            if !outputs.isPickerShown { outputs.reload() }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) { outputs.isPickerShown.toggle() }
        } label: {
            Image(systemName: outputs.current?.symbol ?? "hifispeaker.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(outputs.isPickerShown ? tint : Color.white.opacity(hovering ? 0.9 : 0.36))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(PressableButtonStyle())
        .onHover { hovering = $0 }
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
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("OUTPUT")
                    .font(.system(size: 9.5, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(Color.notchTertiary)
                Spacer(minLength: 0)
                AirPlayButton(tint: tint)
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.notchSecondary)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Color.white.opacity(0.1)))
                        .contentShape(Circle())
                }
                .buttonStyle(PressableButtonStyle())
                .help("Back to the player")
            }
            .frame(height: 20)
            Scroller(.vertical) {
                VStack(spacing: 2) {
                    ForEach(outputs.devices) { device in
                        OutputRow(device: device, isCurrent: device.id == outputs.currentID, tint: tint) {
                            choose(device)
                        }
                    }
                    if outputs.devices.isEmpty {
                        Text("No outputs found.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Color.notchSecondary)
                            .padding(.top, 8)
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(Color.notchCard))
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
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: device.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isCurrent ? tint : Color.notchSecondary)
                    .frame(width: 18)
                Text(device.name)
                    .font(.system(size: 12.5, weight: isCurrent ? .semibold : .medium))
                    .foregroundStyle(Color.white.opacity(isCurrent ? 1 : 0.85))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if isCurrent {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(tint)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(isCurrent ? 0.1 : hovering ? 0.06 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}

/// AVKit's AirPlay button with a label; its device list opens in a popover under the notch.
private struct AirPlayButton: View {
    var tint: Color
    @Environment(\.isSnapshot) private var isSnapshot
    @ViewState private var handle = RoutePickerHandle()
    @ViewState private var hovering = false

    var body: some View {
        HStack(spacing: 3) {
            Group {
                if isSnapshot {
                    Image(systemName: "airplayaudio")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.notchSecondary)
                } else {
                    RoutePicker(handle: handle, tint: NSColor(tint))
                }
            }
            .frame(width: 20, height: 20)
            Text("AirPlay")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.notchSecondary)
        }
        .padding(.leading, 2)
        .padding(.trailing, 9)
        .frame(height: 20)
        .background(Capsule().fill(Color.white.opacity(hovering ? 0.14 : 0.08)))
        .contentShape(Capsule())
        .onTapGesture { handle.present() }
        .onHover { hovering = $0 }
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
