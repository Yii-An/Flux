import SwiftUI
import AppKit

struct QuickActionsBar: View {
    let isRefreshing: Bool
    let onRefresh: () -> Void
    let onCheckUpdates: () -> Void
    let onOpenConfigFolder: () -> Void
    let onOpenAuthFolder: () -> Void
    let onOpenCoreFolder: () -> Void

    var body: some View {
        HStack(spacing: UITokens.Spacing.sm) {
            ActionButton(
                title: "Refresh".localizedStatic(),
                systemImage: "arrow.clockwise",
                tint: .blue,
                isDisabled: isRefreshing
            ) {
                onRefresh()
            }
            .help("Refresh".localizedStatic())

            ActionButton(
                title: "Check Updates".localizedStatic(),
                systemImage: "sparkles",
                tint: .purple
            ) {
                onCheckUpdates()
            }

            ActionButton(
                title: "Open Config Folder".localizedStatic(),
                systemImage: "folder",
                tint: .secondary
            ) {
                onOpenConfigFolder()
            }

            ActionButton(
                title: "Open Auth Folder".localizedStatic(),
                systemImage: "key.horizontal.fill",
                tint: .secondary
            ) {
                onOpenAuthFolder()
            }

            ActionButton(
                title: "Open Core Folder".localizedStatic(),
                systemImage: "bolt.fill",
                tint: .secondary
            ) {
                onOpenCoreFolder()
            }
        }
        .frame(maxWidth: .infinity)
        .padding(UITokens.Spacing.md)
        .fluxCardStyle()
    }
}
