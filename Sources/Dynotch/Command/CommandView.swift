import SwiftUI

/// The command field, over the tabs: what's typed, and what it can do. ↑ and ↓ move through the
/// rows, Return runs the picked one, and Escape clears what's typed, then leaves.
struct CommandView: View {
    @ObservedObject var viewModel: NotchViewModel
    @FocusState private var isFocused: Bool
    @ViewState private var selection = 0
    @Environment(\.notchTheme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot

    static let placeholder = "Type a command, or search notes, files and shortcuts"

    var body: some View {
        let results = viewModel.commandResults
        VStack(alignment: .leading, spacing: 0) {
            field(results)
            Text(viewModel.commandQuery.trimmingCharacters(in: .whitespaces).isEmpty ? "Try" : "Results")
                .font(NotchFont.label)
                .foregroundStyle(theme.tertiary)
                .frame(height: 16)
                .padding(.leading, 6)
                .padding(.top, 10)
                .padding(.bottom, 6)
            VStack(spacing: 2) {
                ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                    CommandRow(result: result, isSelected: index == min(selection, results.count - 1)) {
                        viewModel.run(result)
                    } onHover: {
                        selection = index
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: viewModel.commandQuery) { selection = 0 }
        .task {
            // Once the panel has taken the keyboard, which happens on the next turn of the run loop.
            try? await Task.sleep(for: .milliseconds(60))
            isFocused = true
        }
    }

    private func field(_ results: [CommandResult]) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.accent)
            if isSnapshot {
                Text(viewModel.commandQuery.isEmpty ? Self.placeholder : viewModel.commandQuery)
                    .font(.system(size: 13.5))
                    .foregroundStyle(viewModel.commandQuery.isEmpty ? theme.tertiary : theme.primary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField(Self.placeholder, text: $viewModel.commandQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5))
                    .focused($isFocused)
                    .onSubmit { runSelected(results) }
                    .onKeyPress(.downArrow) {
                        selection = min(selection + 1, max(results.count - 1, 0))
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        selection = max(selection - 1, 0)
                        return .handled
                    }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(shape.fill(theme.control))
        .overlay(shape.strokeBorder(theme.accent.opacity(0.7), lineWidth: 1.5))
        .contentShape(shape)
        .onTapGesture { isFocused = true }
    }

    private func runSelected(_ results: [CommandResult]) {
        guard !results.isEmpty else { return }
        viewModel.run(results[min(selection, results.count - 1)])
    }
}

/// A result: its symbol on a tinted tile, what it does, then what to type for it or its value.
private struct CommandRow: View {
    let result: CommandResult
    let isSelected: Bool
    let action: () -> Void
    let onHover: () -> Void
    @Environment(\.notchTheme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: result.symbol)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(result.tint)
                    .frame(width: 24, height: 24)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(result.tint.opacity(0.18)))
                Text(result.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(result.action == nil ? theme.secondary : theme.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let hint = result.hint {
                    Text(hint)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(theme.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 7)
                        .frame(height: 20)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(theme.control))
                }
                Image(systemName: "return")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(theme.tertiary)
                    .opacity(isSelected && result.action != nil ? 1 : 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(isSelected ? theme.control : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle(scale: 0.98))
        .disabled(result.action == nil)
        .onHover { if $0 { onHover() } }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
