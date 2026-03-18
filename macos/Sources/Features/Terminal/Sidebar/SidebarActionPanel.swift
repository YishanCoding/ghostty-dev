import SwiftUI

/// The state of the first pane in a tab, used to determine which action buttons are enabled.
enum PaneState: Equatable {
    case idle           // Shell prompt — Resume tmux enabled
    case tmuxRunning    // In tmux session — Launch CC + Detach enabled
    case ccRunning      // CC running in tmux — only Detach enabled
    case unknown        // Other program — all disabled
}

/// Action popover content shown when the user clicks the action button on a selected tab.
/// Floats above the terminal pane without affecting layout.
struct SidebarActionPopover: View {
    @ObservedObject var tabManager: SidebarTabManager
    let theme: SidebarTheme
    @Binding var isPresented: Bool

    private var paneState: PaneState { tabManager.selectedPaneState }

    /// Read font size from UserDefaults to match sidebar tab cards.
    private var fontSize: CGFloat {
        let v = UserDefaults.standard.double(forKey: "SidebarFontSize")
        return CGFloat(v > 0 ? v : 12)
    }

    var body: some View {
        VStack(spacing: 6) {
            actionButton(
                "Resume tmux",
                icon: "terminal",
                enabled: paneState == .idle,
                action: { tabManager.launchTmux(); isPresented = false }
            )
            actionButton(
                "Launch CC",
                icon: "sparkle",
                enabled: paneState == .tmuxRunning && !tabManager.isLaunchingCC,
                action: { tabManager.launchCC(); isPresented = false }
            )
            actionButton(
                "Detach tmux",
                icon: "arrow.uturn.left",
                enabled: paneState == .tmuxRunning || paneState == .ccRunning,
                action: { tabManager.detachTmux(); isPresented = false }
            )
        }
        .padding(8)
    }

    @ViewBuilder
    private func actionButton(_ title: String, icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: fontSize))
                Text(title)
                    .font(.system(size: fontSize, weight: .medium))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(enabled ? theme.activeTabBackground : Color.clear)
            .foregroundColor(enabled ? theme.foreground : theme.secondaryText.opacity(0.5))
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}
