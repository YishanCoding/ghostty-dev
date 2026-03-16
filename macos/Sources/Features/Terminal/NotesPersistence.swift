import Foundation

/// Manages reading and writing per-tab notes to ~/.config/ghostty/notes/
enum NotesPersistence {
    private static let notesDirectory: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".config/ghostty/notes", isDirectory: true)
    }()

    /// Ensure the notes directory exists.
    private static func ensureDirectory() {
        try? FileManager.default.createDirectory(
            at: notesDirectory,
            withIntermediateDirectories: true
        )
    }

    /// File URL for a given tab UUID.
    static func fileURL(for id: UUID) -> URL {
        notesDirectory.appendingPathComponent("\(id.uuidString).txt")
    }

    /// Load notes text for a tab. Returns empty string if no file exists.
    static func load(for id: UUID) -> String {
        let url = fileURL(for: id)
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// Save notes text for a tab. Debounce in the caller, not here.
    static func save(_ text: String, for id: UUID) {
        ensureDirectory()
        let url = fileURL(for: id)
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}
