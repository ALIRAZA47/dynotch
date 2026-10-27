import AppKit
import SwiftUI

/// A scratchpad that's always one hover away. Saved as you type.
struct NotesWidget: View {
    @AppStorage("notes.text") private var text = ""
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        WidgetCard(title: "Notes", symbol: "note.text") {
            if !text.isEmpty {
                HStack(spacing: 0) {
                    smallButton("doc.on.doc", help: "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                    smallButton("trash", help: "Clear") { text = "" }
                }
            }
        } content: {
            editor
                .font(.system(size: 11.5))
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Jot something down…")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Color.notchTertiary)
                            .allowsHitTesting(false)
                    }
                }
        }
    }

    @ViewBuilder
    private var editor: some View {
        if isSnapshot {
            Text(text)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            TextEditor(text: $text)
                .scrollContentBackground(.hidden)
                .scrollIndicators(.never)
                .padding(.horizontal, -5)
        }
    }

    private func smallButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9.5, weight: .semibold))
                .frame(width: 18, height: 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .help(help)
    }
}
