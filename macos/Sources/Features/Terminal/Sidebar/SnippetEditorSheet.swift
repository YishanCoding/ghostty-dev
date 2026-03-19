import SwiftUI

/// macOS sheet for adding or editing a snippet.
struct SnippetEditorSheet: View {
    @ObservedObject var store: SnippetStore
    @Binding var isPresented: Bool

    /// If non-nil, we're editing an existing snippet.
    var editing: Snippet?

    @State private var name: String = ""
    @State private var command: String = ""

    var body: some View {
        VStack(spacing: 0) {
            // Header
            Text(editing == nil ? "New Snippet" : "Edit Snippet")
                .font(.headline)
                .padding(.top, 16)
                .padding(.bottom, 12)

            // Form
            Form {
                TextField("Name:", text: $name)
                TextField("Command:", text: $command)
            }
            .formStyle(.grouped)
            .frame(width: 360)
            .padding(.horizontal, 16)

            // Buttons
            HStack {
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(editing == nil ? "Add" : "Save") {
                    if let existing = editing {
                        var updated = existing
                        updated.name = name
                        updated.command = command
                        store.update(updated)
                    } else {
                        store.add(Snippet(name: name, command: command))
                    }
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty || command.isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .frame(width: 400)
        .onAppear {
            if let existing = editing {
                name = existing.name
                command = existing.command
            }
        }
    }
}
