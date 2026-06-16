import SwiftUI
import UniformTypeIdentifiers

// MARK: - SidebarTheme

struct SidebarTheme: Equatable {
    let background: Color
    let foreground: Color
    let secondaryText: Color
    let activeTabBackground: Color
    let attentionColor: Color

    /// Create from Ghostty terminal colors.
    static func from(background: NSColor, foreground: NSColor) -> SidebarTheme {
        let bgLuminance = background.luminance
        let sidebarBg: Color
        if bgLuminance > 0.5 {
            // Light theme: darken sidebar slightly
            sidebarBg = Color(nsColor: background.darken(by: 0.05))
        } else {
            // Dark theme: lighten sidebar slightly
            sidebarBg = Color(nsColor: background.blended(withFraction: 0.08, of: NSColor.white) ?? background)
        }

        let fg = Color(nsColor: foreground)

        return SidebarTheme(
            background: sidebarBg,
            foreground: fg,
            secondaryText: fg.opacity(0.6),
            activeTabBackground: fg.opacity(0.12),
            attentionColor: .orange
        )
    }

    /// Sensible default when no terminal colors are available yet.
    static var `default`: SidebarTheme {
        SidebarTheme(
            background: Color(nsColor: .controlBackgroundColor),
            foreground: .primary,
            secondaryText: .secondary,
            activeTabBackground: Color.accentColor.opacity(0.12),
            attentionColor: .orange
        )
    }
}

// MARK: - SidebarField

enum SidebarField: String, Hashable {
    case title
    case directory
    case gitBranch = "git-branch"
    case status

    static let defaultFields: Set<SidebarField> = [.title, .directory, .gitBranch, .status]
}

// MARK: - SidebarView

/// A vertical sidebar that displays the list of tabs for the current window group.
struct SidebarView: View {
    @ObservedObject var tabManager: SidebarTabManager
    var theme: SidebarTheme
    var fields: Set<SidebarField> = SidebarField.defaultFields

    @AppStorage("SidebarShowCardBorder") private var showCardBorder: Bool = true
    @AppStorage("SidebarFontSize") private var sidebarFontSize: Double = 12
    @State private var draggingTabID: ObjectIdentifier?
    @State private var dropTargetTabID: ObjectIdentifier?
    @State private var showActionPopover: Bool = false
    @State private var showAddSnippet: Bool = false
    @ObservedObject private var snippetStore = SnippetStore.shared
    @AppStorage("SidebarShowProgressBadge") private var showProgressBadge: Bool = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(Array(tabManager.tabs.enumerated()), id: \.element.id) { index, tab in
                    SidebarTabCard(
                        tab: tab,
                        theme: theme,
                        fields: fields,
                        showCardBorder: showCardBorder,
                        showProgressBadge: showProgressBadge
                    )
                            .contentShape(Rectangle())
                            .opacity(draggingTabID == tab.id ? 0.4 : 1.0)
                            .overlay(alignment: .trailing) {
                                if tab.isSelected {
                                    Button {
                                        showActionPopover.toggle()
                                    } label: {
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 8, weight: .bold))
                                            .foregroundColor(theme.secondaryText)
                                            .frame(width: 16, height: 24)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .popover(isPresented: $showActionPopover, arrowEdge: .trailing) {
                                        SidebarActionPopover(
                                            tabManager: tabManager,
                                            snippetStore: snippetStore,
                                            theme: theme,
                                            isPresented: $showActionPopover
                                        )
                                    }
                                }
                            }
                            .overlay(alignment: .top) {
                                if dropTargetTabID == tab.id && draggingTabID != tab.id {
                                    Rectangle()
                                        .fill(Color.accentColor)
                                        .frame(height: 2)
                                        .offset(y: -3)
                                }
                            }
                            .onTapGesture {
                                tabManager.selectTab(tab)
                            }
                            .onDrag {
                                draggingTabID = tab.id
                                return NSItemProvider(object: "\(index)" as NSString)
                            }
                            .onDrop(of: [UTType.text], delegate: TabDropDelegate(
                                tabManager: tabManager,
                                currentTab: tab,
                                currentIndex: index,
                                draggingTabID: $draggingTabID,
                                dropTargetTabID: $dropTargetTabID
                            ))
                            .contextMenu {
                                Button("Rename Tab...") {
                                    tabManager.promptRenameTab(tab)
                                }

                                Divider()

                                Menu("Tab Color") {
                                    ForEach(TerminalTabColor.allCases, id: \.self) { color in
                                        Button {
                                            tabManager.setTabColor(color, for: tab)
                                        } label: {
                                            Label {
                                                Text(color.localizedName)
                                            } icon: {
                                                Image(nsImage: color.swatchImage(selected: color == tab.tabColor))
                                            }
                                        }
                                    }
                                }

                                Toggle("Show Tab Border", isOn: $showCardBorder)

                                Menu("Font Size") {
                                    ForEach([10, 12, 14, 16, 18] as [Double], id: \.self) { size in
                                        Button {
                                            sidebarFontSize = size
                                        } label: {
                                            let label = "\(Int(size))pt"
                                            if sidebarFontSize == size {
                                                Text("\(label) ✓")
                                            } else {
                                                Text(label)
                                            }
                                        }
                                    }
                                }

                                Divider()

                                Button("Close Tab") {
                                    tabManager.closeTab(tab)
                                }

                                Button("Close Other Tabs") {
                                    tabManager.closeOtherTabs(tab)
                                }
                                .disabled(tabManager.tabs.count <= 1)

                                Button("Close Tabs to the Right") {
                                    tabManager.closeTabsToTheRight(of: tab)
                                }
                                .disabled({
                                    guard let idx = tabManager.tabs.firstIndex(where: { $0.id == tab.id }) else { return true }
                                    return idx >= tabManager.tabs.count - 1
                                }())

                                Divider()

                                Button("Add Snippet...") {
                                    showAddSnippet = true
                                }
                            }
                    }
                }
                .padding(.horizontal, 8)
            .padding(.top, 8)
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button("Add Snippet...") {
                showAddSnippet = true
            }
        }
        .sheet(isPresented: $showAddSnippet) {
            SnippetEditorSheet(
                store: snippetStore,
                isPresented: $showAddSnippet
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.background)
    }
}

// MARK: - TabDropDelegate

private struct TabDropDelegate: DropDelegate {
    let tabManager: SidebarTabManager
    let currentTab: SidebarTabManager.TabItem
    let currentIndex: Int
    @Binding var draggingTabID: ObjectIdentifier?
    @Binding var dropTargetTabID: ObjectIdentifier?

    func dropEntered(info: DropInfo) {
        dropTargetTabID = currentTab.id
    }

    func dropExited(info: DropInfo) {
        if dropTargetTabID == currentTab.id {
            dropTargetTabID = nil
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func validateDrop(info: DropInfo) -> Bool {
        draggingTabID != nil && draggingTabID != currentTab.id
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let draggingTabID else { return false }
        guard let sourceIndex = tabManager.tabs.firstIndex(where: { $0.id == draggingTabID }) else { return false }

        tabManager.moveTab(from: sourceIndex, to: currentIndex)

        self.draggingTabID = nil
        self.dropTargetTabID = nil
        return true
    }
}

// MARK: - SidebarTabCard

private struct SidebarTabCard: View {
    let tab: SidebarTabManager.TabItem
    let theme: SidebarTheme
    let fields: Set<SidebarField>
    var showCardBorder: Bool = true
    var showProgressBadge: Bool = false

    /// Read font size directly from UserDefaults to avoid @AppStorage first-frame flash.
    private var fontSize: CGFloat {
        let v = UserDefaults.standard.double(forKey: "SidebarFontSize")
        return CGFloat(v > 0 ? v : 12)
    }
    private var secondaryFontSize: CGFloat { max(fontSize - 2, 8) }
    private var iconFontSize: CGFloat { max(fontSize - 3, 7) }

    private static let cardRadius: CGFloat = 8

    /// The accent color for the left border strip.
    /// Full intensity for the selected tab, dimmed for inactive tabs.
    private var accentColor: Color {
        if let nsColor = tab.tabColor.displayColor {
            let base = Color(nsColor: nsColor)
            return tab.isSelected ? base : base.opacity(0.4)
        }
        return Color(nsColor: .separatorColor).opacity(tab.isSelected ? 0.3 : 0.15)
    }

    /// The border color for the thin card border — always neutral gray.
    private var cardBorderColor: Color {
        Color(nsColor: .separatorColor).opacity(0.3)
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left color accent strip — uses UnevenRoundedRectangle so it
            // follows the card's left-side rounding while staying flat on the right.
            UnevenRoundedRectangle(
                topLeadingRadius: Self.cardRadius,
                bottomLeadingRadius: Self.cardRadius,
                bottomTrailingRadius: 0,
                topTrailingRadius: 0
            )
            .fill(accentColor)
            .frame(width: 5)

            VStack(alignment: .leading, spacing: 4) {
                // Title (always shown — attention dot lives here)
                if fields.contains(.title) {
                    HStack(spacing: 6) {
                        Text(tab.displayTitle)
                            .font(.system(size: CGFloat(fontSize), weight: tab.isSelected ? .semibold : .regular))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .foregroundColor(tab.isSelected ? theme.foreground : theme.secondaryText)

                        Spacer()

                        if tab.needsAttention {
                            Circle()
                                .fill(theme.attentionColor)
                                .frame(width: 8, height: 8)
                        }
                    }
                }

                // Directory name — always reserve space to prevent layout jump
                if fields.contains(.directory) {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                            .font(.system(size: iconFontSize))
                            .foregroundColor(theme.secondaryText)
                        Text(tab.directoryName ?? " ")
                            .font(.system(size: secondaryFontSize))
                            .foregroundColor(theme.secondaryText)
                            .lineLimit(1)
                            .opacity(tab.directoryName != nil ? 1 : 0)
                    }
                }

                // Git branch
                if fields.contains(.gitBranch), let branch = tab.gitBranch {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: iconFontSize))
                            .foregroundColor(theme.secondaryText)
                        Text(branch)
                            .font(.system(size: secondaryFontSize))
                            .foregroundColor(theme.secondaryText)
                            .lineLimit(1)
                    }
                }

                // Run state and cache countdown
                if showsRunStateRow {
                    HStack(spacing: 6) {
                        switch tab.runState {
                        case .ccRunning:
                            Circle()
                                .fill(.green)
                                .frame(width: 6, height: 6)
                            Text("CC running")
                                .font(.system(size: secondaryFontSize))
                                .foregroundColor(.green)
                                .lineLimit(1)

                        case .tmuxAttached:
                            Circle()
                                .fill(.blue)
                                .frame(width: 6, height: 6)
                            Text("tmux")
                                .font(.system(size: secondaryFontSize))
                                .foregroundColor(.blue)
                                .lineLimit(1)

                        case .idle where idleLabel != nil:
                            Image(systemName: "pause.fill")
                                .font(.system(size: iconFontSize))
                                .foregroundColor(theme.secondaryText)
                            Text(idleLabel ?? "")
                                .font(.system(size: secondaryFontSize))
                                .foregroundColor(theme.secondaryText)
                                .lineLimit(1)

                        default:
                            EmptyView()
                        }

                        if let secs = tab.cacheSecondsRemaining {
                            Spacer()
                            Text(cacheLabel(seconds: secs))
                                .font(.system(size: secondaryFontSize, design: .monospaced))
                                .foregroundColor(cacheColor(seconds: secs))
                                .lineLimit(1)
                        }
                    }
                }

                // Status entries
                if fields.contains(.status), !tab.statusEntries.isEmpty {
                    ForEach(tab.statusEntries, id: \.key) { entry in
                        HStack(spacing: 4) {
                            if let icon = entry.icon {
                                Image(systemName: icon)
                                    .font(.system(size: iconFontSize))
                                    .foregroundColor(theme.secondaryText)
                            }
                            Text(entry.value)
                                .font(.system(size: secondaryFontSize))
                                .foregroundColor(theme.secondaryText)
                                .lineLimit(1)
                        }
                    }
                }

                // Latest progress log entry — distinct pill style
                if showProgressBadge, let progress = tab.progressLatest {
                    HStack(spacing: 4) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: max(iconFontSize - 1, 6)))
                            .foregroundColor(.orange)
                        Text(progress)
                            .font(.system(size: max(secondaryFontSize - 2, 7), design: .monospaced))
                            .foregroundColor(theme.foreground.opacity(0.8))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.orange.opacity(0.1))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Color.orange.opacity(0.2), lineWidth: 0.5)
                    )
                }
            }
            .padding(.vertical, 8)
            .padding(.leading, 8)
            .padding(.trailing, 10)
        }
        .clipShape(RoundedRectangle(cornerRadius: Self.cardRadius))
        .background(
            RoundedRectangle(cornerRadius: Self.cardRadius)
                .fill(tab.isSelected ? theme.activeTabBackground : Color.clear)
        )
        .overlay(
            Group {
                if showCardBorder {
                    RoundedRectangle(cornerRadius: Self.cardRadius)
                        .strokeBorder(cardBorderColor, lineWidth: 1)
                }
            }
        )
        .overlay(alignment: .topTrailing) {
            if tab.isSelected {
                // Corner flag — a small triangle bookmark in the top-right
                SelectedTabFlag(color: flagColor)
                    .frame(width: 14, height: 14)
                    .clipShape(
                        UnevenRoundedRectangle(
                            topLeadingRadius: 0,
                            bottomLeadingRadius: 0,
                            bottomTrailingRadius: 0,
                            topTrailingRadius: Self.cardRadius
                        )
                    )
            }
        }
    }

    /// Flag color: use the tab color if set, otherwise a subtle accent tint.
    private var flagColor: Color {
        if let nsColor = tab.tabColor.displayColor {
            return Color(nsColor: nsColor)
        }
        return Color.accentColor.opacity(0.7)
    }

    private var idleMinutes: Int? {
        guard tab.runState == .idle,
              let lastActivityDate = tab.lastActivityDate else { return nil }
        let minutes = Int(Date().timeIntervalSince(lastActivityDate) / 60)
        return minutes >= 30 ? minutes : nil
    }

    private var idleLabel: String? {
        guard let idleMinutes else { return nil }
        if idleMinutes < 60 {
            return "idle \(idleMinutes)m"
        }
        return "idle \(idleMinutes / 60)h"
    }

    private var showsRunStateRow: Bool {
        switch tab.runState {
        case .ccRunning, .tmuxAttached:
            return true
        case .idle:
            return idleLabel != nil || tab.cacheSecondsRemaining != nil
        case .unknown:
            return tab.cacheSecondsRemaining != nil
        }
    }

    private func cacheLabel(seconds: Int) -> String {
        String(format: "cache %d:%02d", seconds / 60, seconds % 60)
    }

    private func cacheColor(seconds: Int) -> Color {
        if seconds >= 240 {
            return .green
        }
        if seconds >= 120 {
            return .yellow
        }
        return .red
    }
}

/// A small triangle drawn in the top-right corner of the selected tab card.
private struct SelectedTabFlag: View {
    let color: Color

    var body: some View {
        Canvas { context, size in
            var path = Path()
            path.move(to: CGPoint(x: 0, y: 0))
            path.addLine(to: CGPoint(x: size.width, y: 0))
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.closeSubpath()
            context.fill(path, with: .color(color))
        }
    }
}
