import Foundation
import Observation

enum LogsSource: String, CaseIterable, Identifiable, Sendable {
    case app
    case core

    var id: String { rawValue }
}

@Observable
@MainActor
final class LogsViewModel {
    var source: LogsSource = .app
    var coreState: CoreRuntimeState = .stopped
    var isLoading: Bool = false
    var entries: [LogRecord] = []
    var errorMessage: String?

    var reversedEntries: [LogRecord] {
        Array(entries.reversed())
    }

    private let coreOrchestrator: CoreOrchestrator
    private let fluxLogger: FluxLogger
    nonisolated(unsafe) private var streamTask: Task<Void, Never>?

    init(coreOrchestrator: CoreOrchestrator = .shared, fluxLogger: FluxLogger = .shared) {
        self.coreOrchestrator = coreOrchestrator
        self.fluxLogger = fluxLogger
    }

    deinit {
        streamTask?.cancel()
    }

    func load() async {
        await applySource(source)
    }

    func deactivate() {
        stopStream()
    }

    func applySource(_ source: LogsSource) async {
        self.source = source
        errorMessage = nil

        switch source {
        case .app:
            await startAppStream()
        case .core:
            stopStream()
            await refreshCoreLogs()
        }
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        errorMessage = nil

        switch source {
        case .app:
            entries = await fluxLogger.recentRecords()
        case .core:
            await refreshCoreLogs()
        }
    }

    func startCore() async {
        await coreOrchestrator.start()
        await refreshCoreLogs()
    }

    func clearLogs() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        errorMessage = nil

        switch source {
        case .app:
            await fluxLogger.clearAppLogs()
            entries = []
        case .core:
            coreState = await coreOrchestrator.runtimeState()
            guard coreState.isRunning else { return }
            do {
                guard let logURL = await coreOrchestrator.logFileURL() else { return }
                try await fluxLogger.clearLogFile(at: logURL)
                entries = []
            } catch {
                errorMessage = String(describing: error)
            }
        }
    }

    private func startAppStream() async {
        stopStream()

        entries = await fluxLogger.recentRecords()

        streamTask = Task { [weak self] in
            guard let self else { return }
            let stream = await self.fluxLogger.stream()
            for await record in stream {
                guard !Task.isCancelled else { break }
                await MainActor.run {
                    self.entries.append(record)
                    if self.entries.count > 2_000 {
                        self.entries.removeFirst(self.entries.count - 2_000)
                    }
                }
            }
        }
    }

    private func stopStream() {
        streamTask?.cancel()
        streamTask = nil
    }

    private func refreshCoreLogs() async {
        coreState = await coreOrchestrator.runtimeState()
        guard coreState.isRunning else {
            entries = []
            return
        }

        do {
            guard let logURL = await coreOrchestrator.logFileURL() else {
                entries = []
                return
            }
            let text = try await fluxLogger.readLogFile(at: logURL)
            let parsed = await Task.detached(priority: .userInitiated) {
                LogEntryParser.parse(text: text, category: LogCategories.core)
            }.value
            entries = parsed
        } catch {
            errorMessage = String(describing: error)
            entries = []
        }
    }
}
