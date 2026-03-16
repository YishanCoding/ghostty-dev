import Foundation
import OSLog

/// Manages reading and writing per-tab notes to ~/.config/ghosttydev/notes/
enum NotesPersistence {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.mitchellh.ghostty",
        category: "NotesPersistence"
    )

    private static let notesDirectory: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".config/ghosttydev/notes", isDirectory: true)
    }()

    /// Ensure the notes directory exists.
    private static func ensureDirectory() {
        do {
            try FileManager.default.createDirectory(
                at: notesDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            logger.warning("Failed to create notes directory: \(error.localizedDescription)")
        }
    }

    /// File URL for a given tab UUID.
    private static func fileURL(for id: UUID) -> URL {
        notesDirectory.appendingPathComponent("\(id.uuidString).txt")
    }

    /// Load notes text for a tab. Returns empty string if no file exists.
    static func load(for id: UUID) -> String {
        let url = fileURL(for: id)
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            // File not existing is expected for new tabs, only log other errors
            if (error as NSError).domain != NSCocoaErrorDomain ||
               (error as NSError).code != NSFileReadNoSuchFileError {
                logger.warning("Failed to load notes for \(id): \(error.localizedDescription)")
            }
            return ""
        }
    }

    /// Save notes text for a tab. Debounce in the caller, not here.
    static func save(_ text: String, for id: UUID) {
        ensureDirectory()
        let url = fileURL(for: id)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            logger.warning("Failed to save notes for \(id): \(error.localizedDescription)")
        }
    }
}
