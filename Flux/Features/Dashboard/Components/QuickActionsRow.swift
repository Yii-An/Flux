import SwiftUI

struct QuickActionsRow: View {
    let isRefreshing: Bool
    let onRefresh: () -> Void
    let onToggleCore: () -> Void
    let onCheckUpdates: () -> Void
    let onOpenConfigFolder: () -> Void

    var body: some View {
        HStack(spacing: UITokens.Spacing.sm) {
            Button {
                onRefresh()
            } label: {
                Label("Refresh".localizedStatic(), systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isRefreshing)

            Button {
                onToggleCore()
            } label: {
                Label("Toggle Core".localizedStatic(), systemImage: "bolt.fill")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button {
                onCheckUpdates()
            } label: {
                Label("Check Updates".localizedStatic(), systemImage: "sparkles")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button {
                onOpenConfigFolder()
            } label: {
                Label("Open Config".localizedStatic(), systemImage: "folder")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Spacer()
        }
        .padding(.horizontal, 2)
    }
}

