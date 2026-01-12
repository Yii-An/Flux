import SwiftUI

struct MenuBarBottomBar: View {
    let onOpenMainWindow: () -> Void
    let onRefresh: @Sendable () async -> Void
    let onOpenSettings: () -> Void
    let onQuit: () -> Void
    let isLoading: Bool

    var body: some View {
        HStack(spacing: 10) {
            Button {
                onOpenMainWindow()
            } label: {
                Image(systemName: "macwindow.and.cursorarrow")
            }
            .buttonStyle(.subtle)
            .help("Open Flux".localizedStatic())

            Spacer()

            Button {
                Task { await onRefresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.subtle)
            .help("Refresh Quota".localizedStatic())
            .disabled(isLoading)

            Menu {
                Button {
                    onOpenSettings()
                } label: {
                    Label("Settings".localizedStatic(), systemImage: "gearshape")
                }

                Divider()

                Button(role: .destructive) {
                    onQuit()
                } label: {
                    Label("Quit Flux".localizedStatic(), systemImage: "power")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .buttonStyle(.subtle)
            .help("More".localizedStatic())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.regularMaterial)
    }
}

