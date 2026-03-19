import Cocoa
import Combine

/// Observes the tab group of a window and publishes tab metadata for the sidebar.
@MainActor
class SidebarTabManager: ObservableObject {
    struct TabItem: Identifiable, Equatable {
        let id: ObjectIdentifier
        let title: String
        let pwd: String?
        let gitBranch: String?
        let surfaceId: UUID?
        let statusEntries: [TabMetadataStore.StatusEntry]
        let isSelected: Bool
        let needsAttention: Bool
        let tabColor: TerminalTabColor
        let progressLatest: String?
        let window: NSWindow

        /// The last path component of the pwd, for compact display.
        var directoryName: String? {
            guard let pwd, !pwd.isEmpty else { return nil }
            return (pwd as NSString).lastPathComponent
        }

        /// Title with bell emoji stripped (the sidebar uses its own attention indicator).
        var displayTitle: String {
            title.hasPrefix("\u{1F514} ") ? String(title.dropFirst(3)) : title
        }

        static func == (lhs: TabItem, rhs: TabItem) -> Bool {
            lhs.id == rhs.id && lhs.title == rhs.title && lhs.isSelected == rhs.isSelected
                && lhs.pwd == rhs.pwd && lhs.gitBranch == rhs.gitBranch
                && lhs.surfaceId == rhs.surfaceId
                && lhs.statusEntries == rhs.statusEntries
                && lhs.needsAttention == rhs.needsAttention
                && lhs.tabColor == rhs.tabColor
                && lhs.progressLatest == rhs.progressLatest
        }
    }

    @Published var tabs: [TabItem] = []

    /// The detected state of the selected tab's first pane.
    @Published var selectedPaneState: PaneState = .unknown

    /// Guard flag to prevent double-invocation of Launch CC within a single poll cycle.
    @Published private(set) var isLaunchingCC: Bool = false

    /// Windows that need attention, cleared when the tab is selected.
    private var attentionWindows: Set<ObjectIdentifier> = []

    /// Whether bells should trigger the sidebar attention indicator.
    /// Derived from `bell-features` containing `attention`.
    private let bellTriggersAttention: Bool

    private weak var window: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?

    init(window: NSWindow, bellTriggersAttention: Bool = true) {
        self.window = window
        self.bellTriggersAttention = bellTriggersAttention
        setupObservers()
        refresh()
    }

    deinit {
        timer?.invalidate()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    private func setupObservers() {
        let center = NotificationCenter.default

        let titleObserver = center.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.refresh() }
        observers.append(titleObserver)

        let resignObserver = center.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.refresh() }
        observers.append(resignObserver)

        // Bell: respect bell-features config
        if bellTriggersAttention {
            let bellObserver = center.addObserver(
                forName: .terminalWindowBellDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self,
                      let controller = notification.object as? BaseTerminalController,
                      let w = controller.window else { return }
                let hasBell = notification.userInfo?[Notification.Name.terminalWindowHasBellKey] as? Bool ?? false
                if hasBell {
                    self.markAttention(window: w)
                } else {
                    self.clearAttention(for: ObjectIdentifier(w))
                    self.refresh()
                }
            }
            observers.append(bellObserver)
        }

        // Desktop notifications (OSC 9/99, command completion): always trigger attention
        let desktopNotifObserver = center.addObserver(
            forName: .ghosttyDesktopNotificationDidFire,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let surfaceView = notification.object as? Ghostty.SurfaceView,
                  let w = surfaceView.window else { return }
            self.markAttention(window: w)
        }
        observers.append(desktopNotifObserver)

        // IPC notifications (tab.notify command): trigger attention
        let ipcNotifObserver = center.addObserver(
            forName: .ghosttyIPCNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let w = notification.object as? NSWindow else { return }
            self.markAttention(window: w)
        }
        observers.append(ipcNotifObserver)

        // Poll periodically for tab group changes, title changes, pwd changes, metadata changes.
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    // MARK: - Attention

    private func markAttention(window w: NSWindow) {
        attentionWindows.insert(ObjectIdentifier(w))
        refresh()
    }

    private func clearAttention(for id: ObjectIdentifier) {
        attentionWindows.remove(id)
    }

    // MARK: - Git Branch

    /// Read the git branch from .git/HEAD in the given directory.
    /// Walks up to find the repo root (supports subdirectories).
    private func gitBranch(at pwd: String) -> String? {
        var dir = pwd
        while dir != "/" {
            let headPath = (dir as NSString).appendingPathComponent(".git/HEAD")
            if let contents = try? String(contentsOfFile: headPath, encoding: .utf8) {
                let prefix = "ref: refs/heads/"
                if contents.hasPrefix(prefix) {
                    return contents.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                return nil // detached HEAD
            }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return nil
    }

    // MARK: - Progress Log

    /// Read the last non-empty line from a progress log file.
    private static func latestProgressLine(session: String) -> String? {
        let path = "/tmp/ghostty-progress/\(session).log"
        guard let data = FileManager.default.contents(atPath: path),
              let content = String(data: data, encoding: .utf8) else { return nil }
        let lines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }
        return lines.last
    }

    // MARK: - Refresh

    func refresh() {
        guard let window else { return }

        let tabWindows: [NSWindow]
        if let tabbedWindows = window.tabbedWindows, !tabbedWindows.isEmpty {
            tabWindows = tabbedWindows
        } else {
            tabWindows = [window]
        }

        let selectedWindow = window.tabGroup?.selectedWindow ?? window
        let metadataStore = TabMetadataStore.shared

        let newTabs = tabWindows.map { w -> TabItem in
            let controller = w.windowController as? BaseTerminalController
            let surface = controller?.surfaceTree.root?.leftmostLeaf()
            let wid = ObjectIdentifier(w)
            let sid = surface?.id
            let pwd = surface?.pwd
            let entries = sid.map { metadataStore.statusEntries(for: $0) } ?? []
            let branch = pwd.flatMap { gitBranch(at: $0) }
            let color = (w as? TerminalWindow)?.tabColor ?? .none
            let progress = controller.flatMap { c -> String? in
                guard let root = c.surfaceTree.root else { return nil }
                let uuidPrefix = String(root.leftmostLeaf().id.uuidString.prefix(8))
                return Self.latestProgressLine(session: Self.sessionPrefix + uuidPrefix)
            }

            return TabItem(
                id: wid,
                title: w.title,
                pwd: pwd,
                gitBranch: branch,
                surfaceId: sid,
                statusEntries: entries,
                isSelected: w === selectedWindow,
                needsAttention: attentionWindows.contains(wid) && w !== selectedWindow,
                tabColor: color,
                progressLatest: progress,
                window: w
            )
        }

        if newTabs != tabs {
            tabs = newTabs
        }

        // Update pane state for the selected tab
        updateSelectedPaneState(selectedWindow: selectedWindow)
    }

    // MARK: - Pane State Detection

    /// Prefix added to tmux session names for easy identification in `tmux ls`.
    private static let sessionPrefix = "GHOSTTYDEV-"

    /// The session name for the selected tab's first pane (e.g. "GHOSTTYDEV-3A7F2B1C").
    var selectedTabUUIDPrefix: String? {
        guard let window else { return nil }
        let selectedWindow = window.tabGroup?.selectedWindow ?? window
        guard let controller = selectedWindow.windowController as? BaseTerminalController,
              let root = controller.surfaceTree.root else { return nil }
        let firstPane = root.leftmostLeaf()
        return Self.sessionPrefix + String(firstPane.id.uuidString.prefix(8))
    }

    /// Cached result of async tmux-attached detection, updated in background.
    private var cachedTmuxAttached: Bool = false
    /// Whether an async tmux check is already in flight.
    private var tmuxCheckInFlight: Bool = false

    /// Cached result of async CC detection, updated in background.
    private var cachedCCRunning: Bool = false
    /// Whether an async CC check is already in flight.
    private var ccCheckInFlight: Bool = false

    private func updateSelectedPaneState(selectedWindow: NSWindow) {
        guard let controller = selectedWindow.windowController as? BaseTerminalController,
              let root = controller.surfaceTree.root else {
            selectedPaneState = .unknown
            return
        }

        let firstPane = root.leftmostLeaf()
        let title = firstPane.title
        let sessionName = Self.sessionPrefix + String(firstPane.id.uuidString.prefix(8))

        let lower = title.lowercased()

        // Detect if pane is INSIDE tmux: title-based (instant) OR async process check (fallback).
        // tmux defaults to `set-titles off`, so the terminal title often won't change —
        // cachedTmuxAttached provides reliable detection via `tmux list-clients`.
        let titleMatch = title.contains(sessionName) || lower.contains("tmux")
        let inTmux = titleMatch || cachedTmuxAttached

        let newState: PaneState
        if inTmux {
            if lower.contains("claude") || cachedCCRunning {
                newState = .ccRunning
            } else {
                newState = .tmuxRunning
            }
            // Kick off async CC check (non-blocking)
            checkCCAsync(sessionName: sessionName)
        } else {
            cachedCCRunning = false
            newState = .idle
        }

        // Always kick off async tmux check to keep cache fresh (detach → idle).
        checkTmuxAsync(sessionName: sessionName)

        if newState != selectedPaneState {
            selectedPaneState = newState
            isLaunchingCC = false
        }
    }

    /// Async check if the tmux session is attached — never blocks the main thread.
    private func checkTmuxAsync(sessionName: String) {
        guard !tmuxCheckInFlight else { return }
        tmuxCheckInFlight = true

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let attached = Self.isTmuxSessionAttached(sessionName)
            DispatchQueue.main.async {
                self?.tmuxCheckInFlight = false
                guard self?.cachedTmuxAttached != attached else { return }
                self?.cachedTmuxAttached = attached
                self?.refresh()
            }
        }
    }

    /// Check if the named tmux session has an attached client.
    /// Returns false if the session doesn't exist or has no clients.
    private static func isTmuxSessionAttached(_ sessionName: String) -> Bool {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-l", "-c", "tmux list-clients -t \(sessionName) -F '#{client_name}' 2>/dev/null | head -1"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let result = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !result.isEmpty
    }

    /// Async check if CC is running — never blocks the main thread.
    private func checkCCAsync(sessionName: String) {
        guard !ccCheckInFlight else { return }
        ccCheckInFlight = true

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let running = Self.isCCRunningInSession(sessionName)
            DispatchQueue.main.async {
                self?.ccCheckInFlight = false
                guard self?.cachedCCRunning != running else { return }
                self?.cachedCCRunning = running
                self?.refresh()
            }
        }
    }

    /// Check if "claude" is a direct child process of the tmux pane's shell.
    /// Runs on a background thread — safe to call waitUntilExit().
    private static func isCCRunningInSession(_ sessionName: String) -> Bool {
        let pipe = Pipe()
        let getPid = Process()
        getPid.executableURL = URL(fileURLWithPath: "/bin/sh")
        getPid.arguments = ["-l", "-c", "tmux list-panes -t \(sessionName) -F '#{pane_pid}' 2>/dev/null | head -1"]
        getPid.standardOutput = pipe
        getPid.standardError = FileHandle.nullDevice
        try? getPid.run()
        getPid.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let pidStr = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !pidStr.isEmpty else { return false }

        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        check.arguments = ["-P", pidStr, "claude"]
        check.standardOutput = FileHandle.nullDevice
        check.standardError = FileHandle.nullDevice
        try? check.run()
        check.waitUntilExit()
        return check.terminationStatus == 0
    }

    // MARK: - Action Panel Actions

    func launchTmux() {
        guard let uuidPrefix = selectedTabUUIDPrefix,
              let surfaceModel = selectedFirstPaneSurfaceModel() else { return }
        // -A flag: attach if session exists, create if not (idempotent).
        // Runs in user's shell so PATH always includes tmux.
        surfaceModel.sendText("tmux new-session -A -s \(uuidPrefix)")
    }

    func launchCC() {
        guard !isLaunchingCC,
              let uuidPrefix = selectedTabUUIDPrefix,
              let surfaceModel = selectedFirstPaneSurfaceModel() else { return }
        isLaunchingCC = true
        surfaceModel.sendText("export AGENT_BROWSER_TABNAME=\(uuidPrefix) && claude --dangerously-skip-permissions")
    }

    func detachTmux() {
        guard let uuidPrefix = selectedTabUUIDPrefix else { return }
        // Run detach via user's login shell to ensure PATH includes tmux.
        // Uses -s flag to target the specific session, works even when
        // an interactive app (CC, vim) is running in the pane.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-l", "-c", "tmux detach-client -s \(uuidPrefix)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    /// Send text to the first pane of the selected tab (no newline appended).
    func sendTextToSelectedPane(_ text: String) {
        guard let surfaceModel = selectedFirstPaneSurfaceModel() else { return }
        surfaceModel.sendText(text)
    }

    /// Get the Ghostty.Surface model for the first pane of the selected tab.
    private func selectedFirstPaneSurfaceModel() -> Ghostty.Surface? {
        guard let window else { return nil }
        let selectedWindow = window.tabGroup?.selectedWindow ?? window
        guard let controller = selectedWindow.windowController as? BaseTerminalController,
              let root = controller.surfaceTree.root else { return nil }
        let firstPane = root.leftmostLeaf()
        return firstPane.surfaceModel
    }

    // MARK: - Tab Actions

    func selectTab(_ tab: TabItem) {
        clearAttention(for: tab.id)
        tab.window.makeKeyAndOrderFront(nil)
    }

    func setTabColor(_ color: TerminalTabColor, for tab: TabItem) {
        (tab.window as? TerminalWindow)?.tabColor = color
        refresh()
    }

    func closeTab(_ tab: TabItem) {
        guard let controller = tab.window.windowController as? TerminalController else { return }
        controller.closeTab(nil)
    }

    func renameTab(_ tab: TabItem, to newTitle: String) {
        guard let controller = tab.window.windowController as? BaseTerminalController else { return }
        controller.titleOverride = newTitle.isEmpty ? nil : newTitle
        refresh()
    }

    func promptRenameTab(_ tab: TabItem) {
        guard let controller = tab.window.windowController as? BaseTerminalController else { return }
        controller.promptTabTitle()
    }

    func closeOtherTabs(_ tab: TabItem) {
        guard let window else { return }
        let tabWindows: [NSWindow]
        if let tabbedWindows = window.tabbedWindows, !tabbedWindows.isEmpty {
            tabWindows = tabbedWindows
        } else {
            return
        }
        for w in tabWindows where ObjectIdentifier(w) != tab.id {
            if let controller = w.windowController as? TerminalController {
                controller.closeTab(nil)
            }
        }
    }

    func moveTab(from sourceIndex: Int, to destinationIndex: Int) {
        guard let window else { return }
        guard let tabbedWindows = window.tabbedWindows, !tabbedWindows.isEmpty else { return }
        guard sourceIndex != destinationIndex,
              sourceIndex >= 0, sourceIndex < tabbedWindows.count,
              destinationIndex >= 0, destinationIndex < tabbedWindows.count else { return }

        let movingWindow = tabbedWindows[sourceIndex]
        let targetWindow = tabbedWindows[destinationIndex]

        if sourceIndex > destinationIndex {
            targetWindow.addTabbedWindow(movingWindow, ordered: .below)
        } else {
            targetWindow.addTabbedWindow(movingWindow, ordered: .above)
        }

        if let selectedWindow = window.tabGroup?.selectedWindow {
            selectedWindow.makeKeyAndOrderFront(nil)
        }

        refresh()
    }

    func closeTabsToTheRight(of tab: TabItem) {
        guard let window else { return }
        let tabWindows: [NSWindow]
        if let tabbedWindows = window.tabbedWindows, !tabbedWindows.isEmpty {
            tabWindows = tabbedWindows
        } else {
            return
        }
        guard let idx = tabWindows.firstIndex(where: { ObjectIdentifier($0) == tab.id }) else { return }
        for w in tabWindows[(idx + 1)...] {
            if let controller = w.windowController as? TerminalController {
                controller.closeTab(nil)
            }
        }
    }
}
