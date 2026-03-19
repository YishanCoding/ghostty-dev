import Foundation
import os

/// A user-defined snippet: a named command that can be sent to the terminal.
struct Snippet: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var command: String
}

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ghostty-dev", category: "SnippetStore")

/// Manages snippets shared across all tabs, persisted to a JSON file.
@MainActor
final class SnippetStore: ObservableObject {
    static let shared = SnippetStore()

    @Published var snippets: [Snippet] = []

    /// True if load() failed to decode the file — prevents save() from overwriting corrupted data.
    private var loadFailed = false

    private let filePath: String = {
        let dir = NSString(string: "~/.config/ghosttydev").expandingTildeInPath
        return (dir as NSString).appendingPathComponent("snippets.json")
    }()

    private init() {
        load()
    }

    func add(_ snippet: Snippet) {
        snippets.append(snippet)
        save()
    }

    func update(_ snippet: Snippet) {
        guard let idx = snippets.firstIndex(where: { $0.id == snippet.id }) else { return }
        snippets[idx] = snippet
        save()
    }

    func delete(_ snippet: Snippet) {
        snippets.removeAll { $0.id == snippet.id }
        save()
    }

    func move(from source: IndexSet, to destination: Int) {
        snippets.move(fromOffsets: source, toOffset: destination)
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = FileManager.default.contents(atPath: filePath) else { return }
        do {
            snippets = try JSONDecoder().decode([Snippet].self, from: data)
        } catch {
            logger.error("Failed to decode snippets from \(self.filePath): \(error.localizedDescription)")
            loadFailed = true
        }
    }

    private func save() {
        if loadFailed {
            logger.warning("Skipping save — previous load failed, refusing to overwrite possibly corrupted file")
            return
        }
        let dir = (filePath as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(snippets)
            try data.write(to: URL(fileURLWithPath: filePath), options: .atomic)
        } catch {
            logger.error("Failed to save snippets to \(self.filePath): \(error.localizedDescription)")
        }
    }
}
