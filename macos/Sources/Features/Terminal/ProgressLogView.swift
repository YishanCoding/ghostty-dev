import SwiftUI

/// Displays the latest progress log entries below the TaskTitleBar.
/// Click to edit the full log file; collapses to zero height when empty.
struct ProgressLogView: View {
    @ObservedObject var watcher: ProgressLogWatcher
    @State private var isEditing = false
    @State private var draft: String = ""
    @FocusState private var isFocused: Bool

    var onDismissFocus: () -> Void

    var body: some View {
        if !watcher.lines.isEmpty || isEditing {
            VStack(spacing: 0) {
                if isEditing {
                    editView
                } else {
                    displayView
                }
                Divider()
            }
        }
    }

    private var displayView: some View {
        Button {
            draft = watcher.allText
            isEditing = true
            isFocused = true
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(watcher.lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .lineLimit(1)
                        .foregroundColor(.secondary)
                }
            }
            .font(.system(size: 12))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var editView: some View {
        textEditor
            .font(.system(size: 12))
            .frame(height: 120)
            .focused($isFocused)
            .onAppear { isFocused = true }
            .backport.onKeyPress(.escape) { _ in
                commitEdit()
                return .handled
            }
            .onChange(of: isFocused) { focused in
                if !focused { commitEdit() }
            }
    }

    @ViewBuilder
    private var textEditor: some View {
        if #available(macOS 14, *) {
            TextEditor(text: $draft)
                .scrollContentBackground(.hidden)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
        } else {
            TextEditor(text: $draft)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
        }
    }

    private func commitEdit() {
        guard isEditing else { return }
        watcher.save(draft)
        isEditing = false
        isFocused = false
        onDismissFocus()
    }
}
