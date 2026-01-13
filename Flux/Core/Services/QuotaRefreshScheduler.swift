import Foundation

actor QuotaRefreshScheduler {
    static let shared = QuotaRefreshScheduler()

    private var refreshTask: Task<Void, Never>?
    private var intervalSeconds: Int = 300
    private let logger: FluxLogger

    init(logger: FluxLogger = .shared) {
        self.logger = logger
    }

    func start(intervalSeconds: Int) async {
        stop()

        guard intervalSeconds > 0 else {
            self.intervalSeconds = 0
            await logger.log(.info, category: LogCategories.quota, message: "Quota auto-refresh disabled")
            return
        }

        self.intervalSeconds = max(60, intervalSeconds)
        let interval = self.intervalSeconds
        let logger = self.logger

        await logger.log(
            .info,
            category: LogCategories.quota,
            metadata: ["intervalSec": .int(interval)],
            message: "Quota auto-refresh started"
        )

        refreshTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { break }
                await logger.log(.debug, category: LogCategories.quota, message: "Auto-refresh triggered")
                _ = await QuotaAggregator.shared.refreshAll(force: false)
            }
        }
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    func updateInterval(_ seconds: Int) async {
        let newInterval = seconds > 0 ? max(60, seconds) : 0

        if newInterval == intervalSeconds {
            if newInterval == 0, refreshTask != nil {
                await start(intervalSeconds: 0)
            }
            return
        }

        await start(intervalSeconds: seconds)
    }
}
