import SwiftUI

/// The command field, open: what it can do fills the panel, and the field itself stays at the foot,
/// where it always is. ↑ and ↓ move through the rows, Return runs the picked one, and Escape clears
/// what's typed, then leaves.
struct CommandView: View {
    @ObservedObject var viewModel: NotchViewModel
    @FocusState private var isFocused: Bool
    @ViewState private var selection = 0
    @Environment(\.notchTheme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot

    static let placeholder = "Type a command, or search notes, files and shortcuts"
    /// A row's height and the gap under it: one every 34 points, as `NotchViewModel.commandHeight`
    /// counts them.
    static let rowHeight: CGFloat = 32
    static let rowGap: CGFloat = 2
    /// The heading over the rows and the gap under it, also counted by `commandHeight`.
    static let headingHeight: CGFloat = 16
    static let headingGap: CGFloat = 4

    var body: some View {
        let results = viewModel.commandResults
        VStack(alignment: .leading, spacing: 0) {
            Text(heading(results))
                .font(NotchFont.label)
                .tracking(0.66)
                .textCase(.uppercase)
                .foregroundStyle(theme.secondary)
                .frame(height: Self.headingHeight)
                .padding(.leading, 10)
                .padding(.bottom, Self.headingGap)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: Self.rowGap) {
                ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                    CommandRow(result: result, isSelected: index == min(selection, results.count - 1)) {
                        viewModel.run(result)
                    } onHover: {
                        selection = index
                    }
                }
            }
            Spacer(minLength: 0)
            field(results)
                .padding(.top, NotchTheme.commandFieldGap)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .orbitHeader("Command", subtitle: subtitle)
        .onChange(of: viewModel.commandQuery) { selection = 0 }
        .task {
            // Once the panel has taken the keyboard, which happens on the next turn of the run loop.
            try? await Task.sleep(for: .milliseconds(60))
            isFocused = true
        }
    }

    private func heading(_ results: [CommandResult]) -> String {
        guard viewModel.commandQuery.trimmingCharacters(in: .whitespaces).isEmpty else { return "Results" }
        return results.contains(where: \.isLearned) ? "Suggestions" : "Try"
    }

    /// "Type, then Return", or what's typed.
    private var subtitle: String {
        let query = viewModel.commandQuery.trimmingCharacters(in: .whitespaces)
        return query.isEmpty ? "Type, then Return" : "“\(query)”"
    }

    /// The field at the foot, as `CommandFoot` draws it, with the keyboard: ringed in the accent with
    /// a soft wash of it round the ring.
    private func field(_ results: [CommandResult]) -> some View {
        let shape = theme.controlShape
        return HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(theme.accentText)
            if isSnapshot {
                Text(viewModel.commandQuery.isEmpty ? Self.placeholder : viewModel.commandQuery)
                    .font(.system(size: 13))
                    .foregroundStyle(viewModel.commandQuery.isEmpty ? theme.tertiary : theme.primary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField(Self.placeholder, text: $viewModel.commandQuery, prompt: Text(""))
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .fieldPlaceholder(Self.placeholder, isEmpty: viewModel.commandQuery.isEmpty,
                                      font: .system(size: 13), color: theme.tertiary)
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
            Text("↑↓ choose")
                .font(.system(size: 11.5))
                .foregroundStyle(theme.secondary)
                .lineLimit(1)
                .fixedSize()
                .accessibilityHidden(true)
            Keycap(label: "esc")
        }
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .frame(height: NotchTheme.commandFieldHeight)
        .background(shape.fill(theme.field))
        .overlay(shape.strokeBorder(theme.accent, lineWidth: 1.5))
        // The wash round the ring, 3 points out, under the field.
        .background(shape.inset(by: -3).fill(theme.accentSoft))
        .contentShape(shape)
        .onTapGesture { isFocused = true }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Command field")
    }

    private func runSelected(_ results: [CommandResult]) {
        guard !results.isEmpty else { return }
        viewModel.run(results[min(selection, results.count - 1)])
    }
}

/// A result: its symbol in a small square, what it does, then what to type for it or its value. The
/// picked one is a solid face of the accent, with Return on a keycap when it can run.
private struct CommandRow: View {
    let result: CommandResult
    let isSelected: Bool
    let action: () -> Void
    let onHover: () -> Void
    @Environment(\.notchTheme) private var theme

    var body: some View {
        // A row that can't run, like "Nothing for …", stands raised when picked, not on the accent.
        let isLit = isSelected && result.action != nil
        let ink = isLit ? theme.onAccent : theme.primary
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: result.symbol)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(isLit ? theme.onAccent : theme.secondary)
                    .frame(width: 24, height: 24)
                    .background(theme.controlShape.fill(isLit ? theme.onAccent.opacity(0.18) : theme.hover))
                Text(result.title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(result.action == nil ? theme.secondary : ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let hint = result.hint {
                    // What to type for it, or its value, set like typed input: one of the few places for mono.
                    // On the accent's face it has no fill of its own, so it reads as well as the title.
                    Text(hint)
                        .font(NotchFont.mono)
                        .foregroundStyle(isLit ? theme.onAccent : theme.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .frame(height: 20)
                        .background {
                            if isLit {
                                theme.controlShape.strokeBorder(theme.onAccent.opacity(0.45))
                            } else {
                                theme.controlShape.fill(theme.hover)
                            }
                        }
                }
                Keycap(label: "↩", style: .onLens)
                    .opacity(isLit ? 1 : 0)
            }
            .padding(.leading, 4)
            .padding(.trailing, 10)
            .frame(height: CommandView.rowHeight)
            .background {
                if isLit {
                    theme.controlShape.fill(theme.accent)
                } else if isSelected {
                    theme.controlShape.fill(theme.raised).overlay(theme.controlShape.strokeBorder(theme.line))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle(scale: 0.99))
        .disabled(result.action == nil)
        .onHover { if $0 { onHover() } }
        .animation(.notchHighlight, value: isSelected)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
