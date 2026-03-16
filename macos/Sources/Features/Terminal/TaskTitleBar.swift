import SwiftUI

/// A compact title bar at the top of each tab for displaying the current task.
/// Click to edit, click away or press Enter/Escape to return to display mode.
/// Features a colored left strip matching the tab's color.
struct TaskTitleBar: View {
    @Binding var text: String
    var tabColor: TerminalTabColor = .none
    @State private var isEditing = false
    @State private var draft: String = ""
    @FocusState private var isFocused: Bool

    /// Called when user finishes editing (focus leaves or Enter/Escape pressed).
    var onDismissFocus: () -> Void

    private var stripColor: Color {
        if let nsColor = tabColor.displayColor {
            return Color(nsColor: nsColor)
        }
        return Color(nsColor: .separatorColor).opacity(0.3)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                // Color strip matching sidebar tab style
                RoundedRectangle(cornerRadius: 2)
                    .fill(stripColor)
                    .frame(width: 4)
                    .padding(.vertical, 6)
                    .padding(.leading, 4)

                Group {
                    if isEditing {
                        editView
                    } else {
                        displayView
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(height: 44)
            .background(Color.primary.opacity(0.04))

            Divider()
        }
    }

    private var displayView: some View {
        Button {
            draft = text
            isEditing = true
            isFocused = true
        } label: {
            HStack {
                if text.isEmpty {
                    Text("Click to set task title...")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(.secondary.opacity(0.5))
                } else {
                    Text(text)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(.primary)
                }
                Spacer()
            }
            .padding(.horizontal, 10)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var editView: some View {
        TextField("Task title...", text: $draft)
            .font(.system(size: 18, weight: .medium))
            .textFieldStyle(.plain)
            .padding(.horizontal, 10)
            .focused($isFocused)
            .onAppear { isFocused = true }
            .onSubmit { commitEdit() }
            .onChange(of: isFocused) { focused in
                if !focused { commitEdit() }
            }
    }

    private func commitEdit() {
        text = draft
        isEditing = false
        isFocused = false
        onDismissFocus()
    }
}
