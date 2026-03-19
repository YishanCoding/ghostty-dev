import Foundation
import Cocoa
import Combine
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ghostty-dev", category: "GhosttyConfigStore")

/// Reads and writes the Ghostty config file (key = value format).
/// Only manages keys we expose in the Settings UI; leaves all other lines untouched.
@MainActor
final class GhosttyConfigStore: ObservableObject {
    static let shared = GhosttyConfigStore()

    // MARK: - Exposed settings

    @Published var windowSaveState: String = "default" {
        didSet { if !isLoading { scheduleSave() } }
    }
    @Published var macosIcon: String = "" {
        didSet { if !isLoading { scheduleSave() } }
    }
    @Published var macosIconGhostColor: String = "" {
        didSet { if !isLoading { scheduleSave() } }
    }
    @Published var macosIconScreenColor: String = "" {
        didSet { if !isLoading { scheduleSave() } }
    }
    @Published var macosIconFrame: String = "" {
        didSet { if !isLoading { scheduleSave() } }
    }

    // MARK: - Internal

    /// All lines from the config file, preserving comments and unknown keys.
    private var allLines: [String] = []
    private var isLoading = false
    private var saveTimer: Timer?

    private var configPath: String {
        // Ghostty Dev uses the same config location as upstream Ghostty
        let xdgConfig = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
            ?? NSString(string: "~/.config").expandingTildeInPath
        return (xdgConfig as NSString).appendingPathComponent("ghostty/config")
    }

    /// Map of config key -> property keypath for two-way sync.
    private static let keyMap: [String: WritableKeyPath<GhosttyConfigStore, String>] = [
        "window-save-state": \.windowSaveState,
        "macos-icon": \.macosIcon,
        "macos-icon-ghost-color": \.macosIconGhostColor,
        "macos-icon-screen-color": \.macosIconScreenColor,
        "macos-icon-frame": \.macosIconFrame,
    ]

    private init() {
        load()
    }

    // MARK: - Load

    func load() {
        isLoading = true
        defer { isLoading = false }

        let fm = FileManager.default
        guard fm.fileExists(atPath: configPath) else { return } // No config file yet — use defaults
        guard let data = fm.contents(atPath: configPath),
              let content = String(data: data, encoding: .utf8) else {
            logger.error("Config file exists but could not be read: \(self.configPath)")
            return
        }

        allLines = content.components(separatedBy: .newlines)

        for line in allLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }

            // Split on first '='
            guard let eqIdx = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[trimmed.startIndex..<eqIdx].trimmingCharacters(in: .whitespaces)
            let value = trimmed[trimmed.index(after: eqIdx)...].trimmingCharacters(in: .whitespaces)

            setValue(key: key, value: value)
        }
    }

    private func setValue(key: String, value: String) {
        switch key {
        case "window-save-state": windowSaveState = value
        case "macos-icon": macosIcon = value
        case "macos-icon-ghost-color": macosIconGhostColor = value
        case "macos-icon-screen-color": macosIconScreenColor = value
        case "macos-icon-frame": macosIconFrame = value
        default: break
        }
    }

    // MARK: - Save

    private func scheduleSave() {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            self?.save()
        }
    }

    func save() {
        saveTimer?.invalidate()

        // Build a set of keys we manage
        var managedKeys = Self.keyMap
        var updatedLines: [String] = []
        var writtenKeys: Set<String> = []

        for line in allLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Preserve comments and blank lines
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                updatedLines.append(line)
                continue
            }

            guard let eqIdx = trimmed.firstIndex(of: "=") else {
                updatedLines.append(line)
                continue
            }

            let key = trimmed[trimmed.startIndex..<eqIdx].trimmingCharacters(in: .whitespaces)

            if let kp = managedKeys[key] {
                let value = self[keyPath: kp]
                if !value.isEmpty {
                    updatedLines.append("\(key) = \(value)")
                }
                // else: empty value means remove the line (reset to default)
                writtenKeys.insert(key)
                managedKeys.removeValue(forKey: key)
            } else {
                updatedLines.append(line)
            }
        }

        // Append any managed keys that weren't in the file yet
        for (key, kp) in Self.keyMap where !writtenKeys.contains(key) {
            let value = self[keyPath: kp]
            if !value.isEmpty {
                updatedLines.append("\(key) = \(value)")
            }
        }

        // Remove trailing empty lines then add one
        while updatedLines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            updatedLines.removeLast()
        }
        updatedLines.append("")

        let content = updatedLines.joined(separator: "\n")
        let dir = (configPath as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try content.write(toFile: configPath, atomically: true, encoding: .utf8)
            allLines = updatedLines
        } catch {
            logger.error("Failed to save config to \(self.configPath): \(error.localizedDescription)")
        }
    }

    /// Open the config file in the default editor.
    func openInEditor() {
        NSWorkspace.shared.open(URL(fileURLWithPath: configPath))
    }
}
