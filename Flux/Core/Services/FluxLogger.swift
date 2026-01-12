import Foundation
import os

enum FluxLogLevel: String, Sendable {
    case debug
    case info
    case warning
    case error
}

actor FluxLogger {
    static let shared = FluxLogger()

    private let subsystem: String
    private var loggerByCategory: [String: Logger] = [:]

    init(subsystem: String = Bundle.main.bundleIdentifier ?? "com.flux.Flux") {
        self.subsystem = subsystem
    }

    func debug(_ message: String, category: String = "Flux") {
        log(.debug, message, category: category)
    }

    func info(_ message: String, category: String = "Flux") {
        log(.info, message, category: category)
    }

    func warning(_ message: String, category: String = "Flux") {
        log(.warning, message, category: category)
    }

    func error(_ message: String, category: String = "Flux") {
        log(.error, message, category: category)
    }

    func log(_ level: FluxLogLevel, _ message: String, category: String = "Flux") {
        let sanitized = sanitize(message)
        let logger = loggerForCategory(category)

        switch level {
        case .debug:
            logger.debug("\(sanitized, privacy: .public)")
        case .info:
            logger.info("\(sanitized, privacy: .public)")
        case .warning:
            logger.warning("\(sanitized, privacy: .public)")
        case .error:
            logger.error("\(sanitized, privacy: .public)")
        }
    }

    private func loggerForCategory(_ category: String) -> Logger {
        if let existing = loggerByCategory[category] {
            return existing
        }
        let logger = Logger(subsystem: subsystem, category: category)
        loggerByCategory[category] = logger
        return logger
    }

    private func sanitize(_ message: String) -> String {
        var value = message

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if !home.isEmpty {
            value = value.replacingOccurrences(of: home, with: "~")
        }

        value = redactRegex(value, pattern: #"(?i)\b(bearer)\s+([A-Za-z0-9._-]{8,})\b"#, replacement: "$1 ***")
        value = redactRegex(value, pattern: #"(?i)\b(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}\b"#, replacement: "***")
        value = redactRegex(value, pattern: #"(?i)\b(sk-[A-Za-z0-9]{8,})\b"#, replacement: "sk-***")
        value = redactRegex(value, pattern: #"(?i)\b(token|access_token|refresh_token|api[_ -]?key)\b\s*[:=]\s*([A-Za-z0-9._-]{8,})"#, replacement: "$1=***")

        return value
    }

    func readLogFile(at url: URL, maxBytes: Int = 200_000) throws -> String {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return ""
        }

        let data = try Data(contentsOf: url)
        let capped = data.count > maxBytes ? data.suffix(maxBytes) : data
        let text = String(data: capped, encoding: .utf8) ?? ""
        return sanitize(text)
    }

    func clearLogFile(at url: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: Data())
        }

        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 0)
        try handle.close()

        try fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: url.path)
    }

    private func redactRegex(_ input: String, pattern: String, replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return input }
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        return regex.stringByReplacingMatches(in: input, options: [], range: range, withTemplate: replacement)
    }
}
