import Cocoa
import OSLog

/// Manages independent JSON-based session persistence for terminal windows and tabs.
/// Replaces macOS NSWindowRestoration with a user-controlled file at ~/.config/ghosttydev/sessions/.
enum SessionPersistence {
    private static let logger = Logger(subsystem: "com.mitchellh.ghostty", category: "session")

    /// Guard flag to suppress saves during restoration.
    private(set) static var isRestoring = false

    /// Guard flag to suppress saves after final termination save.
    private(set) static var isTerminating = false

    private static let sessionsDirectory: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".config/ghosttydev/sessions", isDirectory: true)
    }()

    private static var stateFileURL: URL {
        sessionsDirectory.appendingPathComponent("state.json")
    }

    private static func ensureDirectory() {
        try? FileManager.default.createDirectory(
            at: sessionsDirectory,
            withIntermediateDirectories: true
        )
    }

    // MARK: - State Structures

    /// A single tab's state, mirroring TerminalRestorableState but fully JSON-controlled.
    struct TabState: Codable {
        let focusedSurface: String?
        let surfaceTree: SplitTree<Ghostty.SurfaceView>
        let effectiveFullscreenMode: FullscreenMode?
        let tabColor: TerminalTabColor
        let titleOverride: String?
        let notesID: String?
        let notesIsVisible: Bool

        init(from controller: TerminalController) {
            self.focusedSurface = controller.focusedSurface?.id.uuidString
            self.surfaceTree = controller.surfaceTree
            self.effectiveFullscreenMode = controller.fullscreenStyle?.fullscreenMode
            self.tabColor = (controller.window as? TerminalWindow)?.tabColor ?? .none
            self.titleOverride = controller.titleOverride
            self.notesID = controller.notesID.uuidString
            self.notesIsVisible = controller.notesIsVisible
        }
    }

    /// A window containing one or more tabs.
    struct WindowState: Codable {
        let frame: CodableRect
        let tabs: [TabState]
        let selectedTabIndex: Int
        let isFullscreen: Bool
    }

    /// Top-level session state.
    struct SessionState: Codable {
        let windows: [WindowState]
    }

    /// NSRect is not Codable, so we wrap it.
    struct CodableRect: Codable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double

        init(_ rect: NSRect) {
            self.x = rect.origin.x
            self.y = rect.origin.y
            self.width = rect.size.width
            self.height = rect.size.height
        }

        var nsRect: NSRect {
            NSRect(x: x, y: y, width: width, height: height)
        }
    }

    // MARK: - Save

    /// Final save before app termination. Blocks all subsequent saves.
    static func saveForTermination() {
        save()
        isTerminating = true
    }

    /// Save all terminal windows to the session file.
    static func save() {
        guard !isRestoring && !isTerminating else { return }
        let controllers = TerminalController.all
        guard !controllers.isEmpty else {
            // No windows — remove state file so we don't restore stale state
            try? FileManager.default.removeItem(at: stateFileURL)
            return
        }

        // Group controllers by tab group
        var windowStates: [WindowState] = []
        var seen = Set<ObjectIdentifier>()

        for controller in controllers {
            guard let window = controller.window else { continue }
            let windowID = ObjectIdentifier(window.tabGroup ?? window as AnyObject)
            guard !seen.contains(windowID) else { continue }
            seen.insert(windowID)

            // Collect all tabs in this window's tab group
            let tabbedWindows = window.tabGroup?.windows ?? [window]
            var tabs: [TabState] = []
            var selectedIndex = 0

            for (index, tabWindow) in tabbedWindows.enumerated() {
                guard let tabController = tabWindow.windowController as? TerminalController else { continue }
                tabs.append(TabState(from: tabController))
                if tabWindow == window.tabGroup?.selectedWindow {
                    selectedIndex = index
                }
            }

            guard !tabs.isEmpty else { continue }

            windowStates.append(WindowState(
                frame: CodableRect(window.frame),
                tabs: tabs,
                selectedTabIndex: selectedIndex,
                isFullscreen: window.styleMask.contains(.fullScreen) ||
                    (controller.fullscreenStyle?.isFullscreen ?? false)
            ))
        }

        let state = SessionState(windows: windowStates)

        ensureDirectory()
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(state)
            try data.write(to: stateFileURL, options: .atomic)
        } catch {
            logger.warning("Failed to save session state: \(error.localizedDescription)")
        }
    }

    // MARK: - Load

    /// Load session state from the file. Returns nil if no state exists.
    static func load() -> SessionState? {
        let url = stateFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(SessionState.self, from: data)
        } catch {
            logger.warning("Failed to load session state: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Restore

    /// Restore all windows from the saved session state.
    /// Returns true if windows were restored, false if no state was found.
    @discardableResult
    static func restore(ghostty: Ghostty.App) -> Bool {
        guard let state = load() else { return false }
        guard !state.windows.isEmpty else { return false }

        isRestoring = true
        defer { isRestoring = false }

        for windowState in state.windows {
            guard !windowState.tabs.isEmpty else { continue }

            var firstController: TerminalController?
            var lastWindow: NSWindow?

            for (index, tab) in windowState.tabs.enumerated() {
                let controller = TerminalController.init(
                    ghostty,
                    withSurfaceTree: tab.surfaceTree)
                guard let window = controller.window else { continue }

                // Restore tab properties
                (window as? TerminalWindow)?.tabColor = tab.tabColor
                controller.titleOverride = tab.titleOverride

                // Restore notes
                if let notesIDString = tab.notesID,
                   let restoredID = UUID(uuidString: notesIDString) {
                    controller.notesID = restoredID
                    controller.loadNotes()
                }
                controller.notesIsVisible = tab.notesIsVisible

                // Restore focus
                if let focusedStr = tab.focusedSurface {
                    if let view = controller.surfaceTree.first(where: { $0.id.uuidString == focusedStr }) {
                        controller.focusedSurface = view
                    }
                }

                if index == 0 {
                    firstController = controller
                    lastWindow = window
                    window.setFrame(windowState.frame.nsRect, display: true)
                    controller.showWindow(nil)
                } else if let prevWindow = lastWindow {
                    // Add after the previous tab to preserve order
                    controller.showWindow(nil)
                    prevWindow.addTabbedWindowSafely(window, ordered: .above)
                    lastWindow = window
                }
            }

            // Select the correct tab
            if let tabGroup = firstController?.window?.tabGroup,
               windowState.selectedTabIndex < tabGroup.windows.count {
                tabGroup.windows[windowState.selectedTabIndex].makeKeyAndOrderFront(nil)
            }

            // Restore fullscreen (non-native only; native fullscreen can't be set programmatically this way)
            if windowState.isFullscreen, let fc = firstController {
                if let mode = windowState.tabs.first?.effectiveFullscreenMode, mode != .native {
                    fc.toggleFullscreen(mode: mode)
                }
            }
        }

        return true
    }
}
