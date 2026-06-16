import Cocoa
import Combine

/// Observes the tab group of a window and publishes tab metadata for the sidebar.
@MainActor
class SidebarTabManager: ObservableObject {
    enum TabRunState: Equatable {
        case unknown
        case idle
        case tmuxAttached
        case ccRunning
    }

    struct TabItem: Identifiable, Equatable {
        let id: ObjectIdentifier
        let title: String
        let pwd: String?
        let gitBranch: String?
        let surfaceId: UUID?
        let statusEntries: [TabMetadataStore.StatusEntry]
        let runState: TabRunState
        let lastActivityDate: Date?
        let cacheSecondsRemaining: Int?
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
                && lhs.runState == rhs.runState
                && lhs.lastActivityDate == rhs.lastActivityDate
                && lhs.cacheSecondsRemaining == rhs.cacheSecondsRemaining
                && lhs.needsAttention == rhs.needsAttention
                && lhs.tabColor == rhs.tabColor
                && lhs.progressLatest == rhs.progressLatest
        }
    }

    @Published var tabs: [TabItem] = []
    @Published var tabRunStates: [ObjectIdentifier: TabRunState] = [:]

    /// The detected state of the selected tab's first pane.
    @Published var selectedPaneState: PaneState = .unknown

    /// Guard flag to prevent double-invocation of Launch CC within a single poll cycle.
    @Published private(set) var isLaunchingCC: Bool = false

    /// Windows that need attention, cleared when the tab is selected.
    private var attentionWindows: Set<ObjectIdentifier> = []

    /// Whether bells should trigger the sidebar attention indicator.
    /// Derived from `bell-features` containing `attention`.
    private let bellTriggersAttention: Bool

    private var tabChecksInFlight: Set<ObjectIdentifier> = []
    private var tabLastActivity: [ObjectIdentifier: Date] = [:]
    private var tabCCLastActive: [ObjectIdentifier: Date] = [:]

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
        let previousTabs = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        let now = Date()
        var activeIds: Set<ObjectIdentifier> = []

        let newTabs = tabWindows.map { w -> TabItem in
            let controller = w.windowController as? BaseTerminalController
            let surface = controller?.surfaceTree.root?.leftmostLeaf()
            let wid = ObjectIdentifier(w)
            activeIds.insert(wid)
            let sid = surface?.id
            let pwd = surface?.pwd
            let entries = sid.map { metadataStore.statusEntries(for: $0) } ?? []
            let branch = pwd.flatMap { gitBranch(at: $0) }
            let color = (w as? TerminalWindow)?.tabColor ?? .none
            let runState = tabRunStates[wid] ?? .unknown
            let progress = controller.flatMap { c -> String? in
                guard let root = c.surfaceTree.root else { return nil }
                let uuidPrefix = String(root.leftmostLeaf().id.uuidString.prefix(8))
                return Self.latestProgressLine(session: Self.sessionPrefix + uuidPrefix)
            }

            if let surface {
                checkTabRunStateAsync(tabId: wid, sessionName: Self.sessionName(for: surface))
            } else {
                tabRunStates[wid] = .unknown
            }

            if let previous = previousTabs[wid] {
                if previous.title != w.title || previous.pwd != pwd || previous.runState != runState {
                    tabLastActivity[wid] = now
                }
            } else if tabLastActivity[wid] == nil {
                tabLastActivity[wid] = now
            }

            return TabItem(
                id: wid,
                title: w.title,
                pwd: pwd,
                gitBranch: branch,
                surfaceId: sid,
                statusEntries: entries,
                runState: runState,
                lastActivityDate: tabLastActivity[wid],
                cacheSecondsRemaining: cacheSecondsRemaining(for: wid, now: now),
                isSelected: w === selectedWindow,
                needsAttention: attentionWindows.contains(wid) && w !== selectedWindow,
                tabColor: color,
                progressLatest: progress,
                window: w
            )
        }

        pruneTabState(activeIds: activeIds)

        if newTabs != tabs {
            tabs = newTabs
        }

        // Update pane state for the selected tab
        updateSelectedPaneState(selectedWindow: selectedWindow)
    }

    // MARK: - Pane State Detection

    /// Prefix added to tmux session names for easy identification in `tmux ls`.
    private static let sessionPrefix = "GHOSTTYDEV-"

    private static func sessionName(for surface: Ghostty.SurfaceView) -> String {
        sessionPrefix + String(surface.id.uuidString.prefix(8))
    }

    /// The session name for the selected tab's first pane (e.g. "GHOSTTYDEV-3A7F2B1C").
    var selectedTabUUIDPrefix: String? {
        guard let window else { return nil }
        let selectedWindow = window.tabGroup?.selectedWindow ?? window
        guard let controller = selectedWindow.windowController as? BaseTerminalController,
              let root = controller.surfaceTree.root else { return nil }
        let firstPane = root.leftmostLeaf()
        return Self.sessionName(for: firstPane)
    }

    private func updateSelectedPaneState(selectedWindow: NSWindow) {
        guard let controller = selectedWindow.windowController as? BaseTerminalController,
              let root = controller.surfaceTree.root else {
            selectedPaneState = .unknown
            return
        }

        let firstPane = root.leftmostLeaf()
        let tabId = ObjectIdentifier(selectedWindow)
        checkTabRunStateAsync(tabId: tabId, sessionName: Self.sessionName(for: firstPane))

        let newState: PaneState
        switch tabRunStates[tabId] ?? .unknown {
        case .idle:
            newState = .idle
        case .tmuxAttached:
            newState = .tmuxRunning
        case .ccRunning:
            newState = .ccRunning
        case .unknown:
            newState = .unknown
        }

        if newState != selectedPaneState {
            selectedPaneState = newState
            isLaunchingCC = false
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

    /// Async check for a tab's tmux/CC state — never blocks the main thread.
    private func checkTabRunStateAsync(tabId: ObjectIdentifier, sessionName: String) {
        guard !tabChecksInFlight.contains(tabId) else { return }
        tabChecksInFlight.insert(tabId)

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let ccRunning = Self.isCCRunningInSession(sessionName)
            let attached = Self.isTmuxSessionAttached(sessionName)
            let newState: TabRunState
            if ccRunning {
                newState = .ccRunning
            } else if attached {
                newState = .tmuxAttached
            } else {
                newState = .idle
            }

            DispatchQueue.main.async {
                guard let self else { return }
                self.tabChecksInFlight.remove(tabId)
                guard let tabWindow = self.tabWindow(for: tabId),
                      let surface = self.firstPane(in: tabWindow),
                      Self.sessionName(for: surface) == sessionName else { return }
                self.applyTabRunState(newState, for: tabId, window: tabWindow, surfaceId: surface.id)
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

    private func applyTabRunState(_ newState: TabRunState, for id: ObjectIdentifier, window w: NSWindow, surfaceId: UUID) {
        let oldState = tabRunStates[id] ?? .unknown
        guard oldState != newState else { return }

        tabRunStates[id] = newState

        if newState == .ccRunning {
            tabCCLastActive[id] = Date()
        }

        if oldState == .ccRunning && newState != .ccRunning {
            TabMetadataStore.shared.setStatus(
                tabId: surfaceId,
                key: "cc_done",
                value: "CC done",
                icon: "checkmark.circle"
            )
            markAttention(window: w)
        } else {
            refresh()
        }
    }

    private func firstPane(in w: NSWindow) -> Ghostty.SurfaceView? {
        guard let controller = w.windowController as? BaseTerminalController else { return nil }
        return controller.surfaceTree.root?.leftmostLeaf()
    }

    private func tabWindow(for id: ObjectIdentifier) -> NSWindow? {
        guard let window else { return nil }
        let tabWindows: [NSWindow]
        if let tabbedWindows = window.tabbedWindows, !tabbedWindows.isEmpty {
            tabWindows = tabbedWindows
        } else {
            tabWindows = [window]
        }
        return tabWindows.first { ObjectIdentifier($0) == id }
    }

    private func cacheSecondsRemaining(for id: ObjectIdentifier, now: Date) -> Int? {
        guard let lastActive = tabCCLastActive[id] else { return nil }
        let elapsed = now.timeIntervalSince(lastActive)
        return elapsed < 300 ? max(0, 300 - Int(elapsed)) : nil
    }

    private func pruneTabState(activeIds: Set<ObjectIdentifier>) {
        let prunedRunStates = tabRunStates.filter { activeIds.contains($0.key) }
        if prunedRunStates != tabRunStates {
            tabRunStates = prunedRunStates
        }
        tabChecksInFlight.formIntersection(activeIds)
        tabLastActivity = tabLastActivity.filter { activeIds.contains($0.key) }
        tabCCLastActive = tabCCLastActive.filter { activeIds.contains($0.key) }
        attentionWindows.formIntersection(activeIds)
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
              let surfaceModel = selectedFirstPaneSurfaceModel() else { return }
        isLaunchingCC = true
        surfaceModel.sendText("claude --dangerously-skip-permissions")
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
        if let surfaceId = tab.surfaceId {
            TabMetadataStore.shared.clearStatus(tabId: surfaceId, key: "cc_done")
        }
        tab.window.makeKeyAndOrderFront(nil)
        refresh()
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
