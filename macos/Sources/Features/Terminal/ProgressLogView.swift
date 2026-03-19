import SwiftUI

/// Displays the latest progress log entries below the TaskTitleBar.
/// Read-only display; collapses to zero height when empty.
struct ProgressLogView: View {
    @ObservedObject var watcher: ProgressLogWatcher

    var onDismissFocus: () -> Void

    var body: some View {
        if !watcher.lines.isEmpty {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(watcher.lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .lineLimit(1)
                            .foregroundColor(.secondary)
                    }
                }
                .font(.system(size: 12))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(nsColor: .windowBackgroundColor))

                Divider()
            }
        }
    }
}
