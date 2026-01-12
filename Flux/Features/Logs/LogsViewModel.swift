import Foundation
import Observation

struct LogEntry: Identifiable, Hashable, Sendable {
    let id: Int
    let level: FluxLogLevel
    let message: String
    let timestamp: Date
}

@Observable
@MainActor
final class LogsViewModel {
    var coreState: CoreRuntimeState = .stopped
    var isLoading: Bool = false
    var entries: [LogEntry] = []
    var errorMessage: String?

    private let coreManager: CoreManager
    private let fluxLogger: FluxLogger

    init(coreManager: CoreManager = .shared, fluxLogger: FluxLogger = .shared) {
        self.coreManager = coreManager
        self.fluxLogger = fluxLogger
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        errorMessage = nil
        coreState = await coreManager.state()

        guard coreState.isRunning else {
            entries = []
            return
        }

        do {
            let logURL = await coreManager.logFileURL()
            let text = try await fluxLogger.readLogFile(at: logURL)
            let parsed = await Task.detached(priority: .userInitiated) {
                LogEntryParser.parse(text: text)
            }.value
            entries = parsed
        } catch {
            errorMessage = String(describing: error)
            entries = []
        }
    }

    func startCore() async {
        await coreManager.start()
        await refresh()
    }

    func clearLogs() async {
        errorMessage = nil
        coreState = await coreManager.state()

        guard coreState.isRunning else {
            return
        }

        do {
            let logURL = await coreManager.logFileURL()
            try await fluxLogger.clearLogFile(at: logURL)
            entries = []
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private func parseEntries(from text: String) -> [LogEntry] {
        let lines = text
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let cappedLines = lines.suffix(1_000)
        let baseTime = Date()

        let isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let isoPlain = ISO8601DateFormatter()
        isoPlain.formatOptions = [.withInternetDateTime]

        let posixLocale = Locale(identifier: "en_US_POSIX")
        let timezone = TimeZone.current

        let dateTimeWithMilliseconds = DateFormatter()
        dateTimeWithMilliseconds.locale = posixLocale
        dateTimeWithMilliseconds.timeZone = timezone
        dateTimeWithMilliseconds.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"

        let dateTimePlain = DateFormatter()
        dateTimePlain.locale = posixLocale
        dateTimePlain.timeZone = timezone
        dateTimePlain.dateFormat = "yyyy-MM-dd HH:mm:ss"

        func parseTimestamp(_ value: String) -> Date? {
            if let date = isoFractional.date(from: value) {
                return date
            }
            if let date = isoPlain.date(from: value) {
                return date
            }
            if let date = dateTimeWithMilliseconds.date(from: value) {
                return date
            }
            if let date = dateTimePlain.date(from: value) {
                return date
            }
            return nil
        }

        func parseLine(_ line: String, fallbackTimestamp: Date) -> (message: String, timestamp: Date) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return ("", fallbackTimestamp) }

            if trimmed.hasPrefix("["),
               let closingBracket = trimmed.firstIndex(of: "]")
            {
                let candidate = String(trimmed[trimmed.index(after: trimmed.startIndex)..<closingBracket])
                if let date = parseTimestamp(candidate) {
                    let remainderStart = trimmed.index(after: closingBracket)
                    let message = trimmed[remainderStart...].trimmingCharacters(in: .whitespacesAndNewlines)
                    return (message.isEmpty ? trimmed : message, date)
                }
            }

            guard let firstSpace = trimmed.firstIndex(of: " ") else {
                if let date = parseTimestamp(trimmed) {
                    return ("", date)
                }
                return (trimmed, fallbackTimestamp)
            }

            let firstToken = String(trimmed[..<firstSpace])
            let remaining = trimmed[trimmed.index(after: firstSpace)...].trimmingCharacters(in: .whitespacesAndNewlines)

            if let date = parseTimestamp(firstToken) {
                return (remaining.isEmpty ? trimmed : remaining, date)
            }

            if isDateToken(firstToken),
               let secondSpace = remaining.firstIndex(of: " ")
            {
                let secondToken = String(remaining[..<secondSpace])
                let candidate = "\(firstToken) \(secondToken)"
                if let date = parseTimestamp(candidate) {
                    let messageStart = remaining.index(after: secondSpace)
                    let message = remaining[messageStart...].trimmingCharacters(in: .whitespacesAndNewlines)
                    return (message.isEmpty ? trimmed : message, date)
                }
            }

            if isDateToken(firstToken), let date = parseTimestamp("\(firstToken) \(remaining)") {
                return ("", date)
            }

            return (trimmed, fallbackTimestamp)
        }

        func isDateToken(_ token: String) -> Bool {
            guard token.count == 10 else { return false }
            let characters = Array(token)
            guard characters[4] == "-", characters[7] == "-" else { return false }
            return characters.enumerated().allSatisfy { index, character in
                if index == 4 || index == 7 { return character == "-" }
                return character.isNumber
            }
        }

        return cappedLines.enumerated().map { index, line in
            let fallback = baseTime.addingTimeInterval(TimeInterval(index - cappedLines.count + 1))
            let parsed = parseLine(line, fallbackTimestamp: fallback)
            return LogEntry(
                id: index,
                level: inferLevel(from: parsed.message.isEmpty ? line : parsed.message),
                message: parsed.message.isEmpty ? line : parsed.message,
                timestamp: parsed.timestamp
            )
        }
    }

    private func inferLevel(from line: String) -> FluxLogLevel {
        let lowercased = line.lowercased()
        if lowercased.contains("error") {
            return .error
        }
        if lowercased.contains("warn") {
            return .warning
        }
        if lowercased.contains("debug") {
            return .debug
        }
        return .info
    }
}
