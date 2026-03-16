import SwiftUI

/// The state of the first pane in a tab, used to determine which action buttons are enabled.
enum PaneState: Equatable {
    case idle           // Shell prompt — Launch tmux enabled
    case tmuxRunning    // In tmux session — Launch CC + Detach enabled
    case ccRunning      // CC running in tmux — only Detach enabled
    case unknown        // Other program — all disabled
}

/// Collapsible action panel displayed as an independent column next to the sidebar.
/// Observes SidebarTabManager directly for live state updates.
/// Collapsed: narrow strip with chevron toggle + icon-only buttons.
/// Expanded: full-width panel with labeled buttons.
struct SidebarActionPanel: View {
    @ObservedObject var tabManager: SidebarTabManager
    let theme: SidebarTheme

    @AppStorage("SidebarActionPanelExpanded") private var isExpanded: Bool = false

    private var panelWidth: CGFloat { isExpanded ? 120 : 32 }
    private var paneState: PaneState { tabManager.selectedPaneState }

    var body: some View {
        VStack(spacing: 0) {
            // Spacer to align with the selected tab's Y position
            Spacer()
                .frame(height: max(tabManager.selectedTabYOffset, 0))

            // Toggle button
            Button {
                isExpanded.toggle()
            } label: {
                Image(systemName: isExpanded ? "chevron.left" : "chevron.right")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(theme.secondaryText)
                    .frame(width: panelWidth, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Collapse action panel" : "Expand action panel")

            // Action buttons
            VStack(spacing: isExpanded ? 8 : 6) {
                actionButton(
                    "Launch tmux",
                    icon: "terminal",
                    enabled: paneState == .idle,
                    action: { tabManager.launchTmux() }
                )
                actionButton(
                    "Launch CC",
                    icon: "sparkle",
                    enabled: paneState == .tmuxRunning && !tabManager.isLaunchingCC,
                    action: { tabManager.launchCC() }
                )
                actionButton(
                    "Detach tmux",
                    icon: "arrow.uturn.left",
                    enabled: paneState == .tmuxRunning || paneState == .ccRunning,
                    action: { tabManager.detachTmux() }
                )
            }
            .padding(.top, 4)
            .padding(.horizontal, isExpanded ? 8 : 4)

            Spacer()
        }
        .frame(width: panelWidth)
        .frame(maxHeight: .infinity)
        .background(theme.background)
        // No SwiftUI animation — NSSplitView divider handles the transition
    }

    @ViewBuilder
    private func actionButton(_ title: String, icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if isExpanded {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .font(.system(size: 12))
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(enabled ? theme.activeTabBackground : theme.background.opacity(0.5))
                .foregroundColor(enabled ? theme.foreground : theme.secondaryText.opacity(0.5))
                .cornerRadius(6)
            } else {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .frame(width: 24, height: 24)
                    .background(enabled ? theme.activeTabBackground : Color.clear)
                    .foregroundColor(enabled ? theme.foreground : theme.secondaryText.opacity(0.4))
                    .cornerRadius(4)
            }
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(title)
    }
}
