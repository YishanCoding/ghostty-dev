import SwiftUI

/// A small scratchpad panel for quick notes, displayed at the bottom of each tab.
struct NotesPanel: View {
    @Binding var text: String
    @FocusState private var isFocused: Bool

    /// Notify parent when user presses Escape to return focus to terminal.
    var onDismissFocus: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()

            textEditor
                .font(.system(.body, design: .monospaced))
                .frame(height: 90)
                .focused($isFocused)
                .onAppear { isFocused = true }
                .backport.onKeyPress(.escape) { _ in
                    isFocused = false
                    onDismissFocus()
                    return .handled
                }
                .overlay(alignment: .topLeading) {
                    if text.isEmpty && !isFocused {
                        Text("Notes...")
                            .foregroundColor(.secondary)
                            .font(.system(.body, design: .monospaced))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                }
        }
    }

    @ViewBuilder
    private var textEditor: some View {
        if #available(macOS 14, *) {
            TextEditor(text: $text)
                .scrollContentBackground(.hidden)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
        } else {
            TextEditor(text: $text)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
        }
    }
}
