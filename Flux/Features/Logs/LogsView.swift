import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct LogsView: View {
    @State private var viewModel = LogsViewModel()
    @State private var filterLevel: FluxLogLevel?

    var body: some View {
        Group {
            if !viewModel.coreState.isRunning {
                CoreOfflineView(
                    coreState: viewModel.coreState,
                    onStart: {
                        await viewModel.startCore()
                    },
                    onInstallFromFile: {
                        showInstallFromFilePanel()
                    }
                )
            } else {
                VStack(spacing: UITokens.Spacing.md) {
                    if let errorMessage = viewModel.errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }

                    HStack(spacing: UITokens.Spacing.md) {
                        Picker("Level".localizedStatic(), selection: $filterLevel) {
                            Text("All".localizedStatic()).tag(nil as FluxLogLevel?)
                            Text("Debug".localizedStatic()).tag(FluxLogLevel.debug as FluxLogLevel?)
                            Text("Info".localizedStatic()).tag(FluxLogLevel.info as FluxLogLevel?)
                            Text("Warning".localizedStatic()).tag(FluxLogLevel.warning as FluxLogLevel?)
                            Text("Error".localizedStatic()).tag(FluxLogLevel.error as FluxLogLevel?)
                        }
                        .pickerStyle(.segmented)

                        Spacer()
                    }
                    .padding(.horizontal)

                    Divider()

                    if filteredEntries.isEmpty {
                        ContentUnavailableView {
                            Label("No Logs".localizedStatic(), systemImage: "doc.text")
                        } description: {
                            Text("No log entries available for the current filter.".localizedStatic())
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding()
                    } else {
                        List(filteredEntries) { entry in
                            LogRow(entry: entry)
                                .listRowInsets(EdgeInsets(top: UITokens.Spacing.xs, leading: UITokens.Spacing.md, bottom: UITokens.Spacing.xs, trailing: UITokens.Spacing.md))
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                        }
                        .listStyle(.inset)
                        .scrollContentBackground(.hidden)
                    }
                }
            }
        }
        .task {
            await viewModel.refresh()
        }
        .toolbar {
            ToolbarItemGroup {
                Button(role: .destructive) {
                    Task { await viewModel.clearLogs() }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.toolbarIcon)
                .help("Clear".localizedStatic())
                .disabled(viewModel.isLoading)

                Button {
                    Task { await viewModel.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.toolbarIcon)
                .help("Refresh".localizedStatic())
                .disabled(viewModel.isLoading)
            }
        }
        .animation(UITokens.Animation.transition, value: viewModel.entries.count)
    }

    private func showInstallFromFilePanel() {
        let panel = NSOpenPanel()
        if #available(macOS 11.0, *) {
            panel.allowedContentTypes = [UTType.unixExecutable]
        }
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Select Flux Core binary".localizedStatic()

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task {
                do {
                    guard FileManager.default.isExecutableFile(atPath: url.path) else {
                        await MainActor.run { viewModel.errorMessage = "Selected file is not executable".localizedStatic() }
                        return
                    }
                    _ = try await CoreVersionManager.shared.installVersion(from: url, version: "custom", setActive: true)
                    await CoreManager.shared.start()
                    await viewModel.refresh()
                } catch {
                    await MainActor.run { viewModel.errorMessage = error.localizedDescription }
                }
            }
        }
    }

    private var filteredEntries: [LogEntry] {
        guard let filterLevel else { return viewModel.entries }
        return viewModel.entries.filter { $0.level == filterLevel }
    }
}

private struct LogRow: View {
    let entry: LogEntry
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            Text(tagText)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.1), in: Capsule())
                .foregroundStyle(.secondary)

            Text(primaryText)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)

            Spacer()

            Text(entry.timestamp, style: .time)
                .font(.dinNumber(.caption))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: UITokens.Radius.medium)
                .fill(isHovering ? Color.primary.opacity(0.04) : .clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(UITokens.Animation.hover) {
                isHovering = hovering
            }
        }
        .fluxCardStyle()
    }

    private var trimmedMessage: String {
        entry.message.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var tagText: String {
        if let method = httpMethod {
            return method
        }
        return entry.level.rawValue.uppercased()
    }

    private var primaryText: String {
        if let path = httpPath {
            return path
        }
        return trimmedMessage
    }

    private var statusColor: Color {
        if let code = httpStatusCode {
            switch code {
            case 200..<300:
                return .green
            case 400..<500:
                return .orange
            case 500..<600:
                return .red
            default:
                return .secondary
            }
        }

        switch entry.level {
        case .error:
            return .red
        case .warning:
            return .orange
        default:
            return .green
        }
    }

    private var httpMethod: String? {
        let parts = trimmedMessage.split(separator: " ", omittingEmptySubsequences: true)
        guard let first = parts.first else { return nil }

        switch first {
        case "GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS":
            return String(first)
        default:
            return nil
        }
    }

    private var httpPath: String? {
        let parts = trimmedMessage.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        guard httpMethod != nil else { return nil }
        return String(parts[1])
    }

    private var httpStatusCode: Int? {
        if let code = statusCodeFromMarkers() {
            return code
        }

        let parts = trimmedMessage.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard let last = parts.last else { return nil }
        let cleaned = String(last).trimmingCharacters(in: CharacterSet(charactersIn: "[](){}<>,;"))
        guard cleaned.count == 3, let code = Int(cleaned), (100...599).contains(code) else { return nil }
        return code
    }

    private func statusCodeFromMarkers() -> Int? {
        let markers = ["status=", "status:", "code=", "code:"]
        let lowercased = trimmedMessage.lowercased()

        for marker in markers {
            guard let range = lowercased.range(of: marker) else { continue }
            let suffix = trimmedMessage[range.upperBound...]
            let digits = suffix.prefix { $0.isNumber }
            if digits.count == 3, let code = Int(digits), (100...599).contains(code) {
                return code
            }
        }

        return nil
    }
}
