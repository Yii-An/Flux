import Foundation
import os

enum FluxLogLevel: String, Codable, Sendable {
    case debug
    case info
    case warning
    case error
}

extension FluxLogLevel {
    var rank: Int {
        switch self {
        case .debug: return 10
        case .info: return 20
        case .warning: return 30
        case .error: return 40
        }
    }

    var osLogType: OSLogType {
        switch self {
        case .debug: return .debug
        case .info: return .info
        case .warning: return .info
        case .error: return .error
        }
    }
}

extension FluxLogLevel: Comparable {
    static func < (lhs: FluxLogLevel, rhs: FluxLogLevel) -> Bool {
        lhs.rank < rhs.rank
    }
}

typealias LogCategory = String

enum LogCategories {
    static let app: LogCategory = "App"
    static let core: LogCategory = "Core"
    static let network: LogCategory = "Network"
    static let quota: LogCategory = "Quota"
    static let quotaAggregator: LogCategory = "Quota.Aggregator"
    static let quotaClaude: LogCategory = "Quota.Claude"
    static let quotaCodex: LogCategory = "Quota.Codex"
    static let quotaAntigravity: LogCategory = "Quota.Antigravity"
    static let quotaGeminiCLI: LogCategory = "Quota.GeminiCLI"
    static let quotaCopilot: LogCategory = "Quota.Copilot"
    static let auth: LogCategory = "Auth"
    static let ui: LogCategory = "UI"
    static let settings: LogCategory = "Settings"
    static let flux: LogCategory = "Flux"
}

enum LogValue: Codable, Sendable, Hashable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case redacted
}

extension LogValue: ExpressibleByStringLiteral {
    init(stringLiteral value: StringLiteralType) { self = .string(value) }
}

extension LogValue: ExpressibleByIntegerLiteral {
    init(integerLiteral value: IntegerLiteralType) { self = .int(value) }
}

extension LogValue: ExpressibleByFloatLiteral {
    init(floatLiteral value: FloatLiteralType) { self = .double(value) }
}

extension LogValue: ExpressibleByBooleanLiteral {
    init(booleanLiteral value: BooleanLiteralType) { self = .bool(value) }
}

struct LogRecord: Identifiable, Sendable, Hashable, Codable {
    var id: UUID
    var timestamp: Date
    var level: FluxLogLevel
    var category: LogCategory
    var message: String
    var metadata: [String: LogValue]
}

struct LogConfig: Codable, Sendable, Hashable {
    var globalMinLevel: FluxLogLevel
    var categoryMinLevels: [LogCategory: FluxLogLevel]

    var enableOSLog: Bool
    var enableFile: Bool
    var enableMemory: Bool

    var fileMaxBytes: Int
    var fileMaxFiles: Int
    var memoryCapacity: Int

    init(
        globalMinLevel: FluxLogLevel = LogConfig.defaultGlobalMinLevel,
        categoryMinLevels: [LogCategory: FluxLogLevel] = [:],
        enableOSLog: Bool = true,
        enableFile: Bool = true,
        enableMemory: Bool = true,
        fileMaxBytes: Int = 5 * 1024 * 1024,
        fileMaxFiles: Int = 5,
        memoryCapacity: Int = 2000
    ) {
        self.globalMinLevel = globalMinLevel
        self.categoryMinLevels = categoryMinLevels
        self.enableOSLog = enableOSLog
        self.enableFile = enableFile
        self.enableMemory = enableMemory
        self.fileMaxBytes = fileMaxBytes
        self.fileMaxFiles = fileMaxFiles
        self.memoryCapacity = memoryCapacity
    }

    func minLevel(for category: LogCategory) -> FluxLogLevel {
        categoryMinLevels[category] ?? globalMinLevel
    }

    private static var defaultGlobalMinLevel: FluxLogLevel {
#if DEBUG
        return .debug
#else
        return .info
#endif
    }
}

protocol LogSink: Sendable {
    func write(_ record: LogRecord) async
}

actor OSLogSink: LogSink {
    private let subsystem: String
    private var loggerByCategory: [LogCategory: Logger] = [:]

    init(subsystem: String) {
        self.subsystem = subsystem
    }

    func write(_ record: LogRecord) async {
        let logger = loggerForCategory(record.category)
        let meta = formatMetadata(record.metadata)
        let text = meta.isEmpty ? record.message : "\(record.message) \(meta)"

        switch record.level {
        case .debug:
            logger.debug("\(text, privacy: .public)")
        case .info:
            logger.info("\(text, privacy: .public)")
        case .warning:
            logger.info("\(text, privacy: .public)")
        case .error:
            logger.error("\(text, privacy: .public)")
        }
    }

    private func loggerForCategory(_ category: LogCategory) -> Logger {
        if let existing = loggerByCategory[category] {
            return existing
        }
        let logger = Logger(subsystem: subsystem, category: category)
        loggerByCategory[category] = logger
        return logger
    }

    private func formatMetadata(_ metadata: [String: LogValue]) -> String {
        guard metadata.isEmpty == false else { return "" }
        let joined = metadata.keys.sorted().compactMap { key in
            guard let value = metadata[key] else { return nil }
            return "\(key)=\(value.displayString)"
        }.joined(separator: " ")
        return joined.isEmpty ? "" : "[\(joined)]"
    }
}

actor MemoryLogSink: LogSink {
    private var capacity: Int
    private var buffer: [LogRecord] = []
    private var continuations: [UUID: AsyncStream<LogRecord>.Continuation] = [:]

    init(capacity: Int) {
        self.capacity = max(100, capacity)
    }

    func updateCapacity(_ capacity: Int) {
        self.capacity = max(100, capacity)
        if buffer.count > self.capacity {
            buffer.removeFirst(buffer.count - self.capacity)
        }
    }

    func stream() -> AsyncStream<LogRecord> {
        AsyncStream { continuation in
            let id = UUID()
            continuations[id] = continuation
            continuation.onTermination = { @Sendable _ in
                Task { await self.removeContinuation(id) }
            }
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }

    func recentRecords() -> [LogRecord] {
        buffer
    }

    func clear() {
        buffer.removeAll(keepingCapacity: true)
    }

    func write(_ record: LogRecord) async {
        buffer.append(record)
        if buffer.count > capacity {
            buffer.removeFirst(buffer.count - capacity)
        }
        for continuation in continuations.values {
            continuation.yield(record)
        }
    }
}

actor RotatingFileSink: LogSink {
    private let fileManager: FileManager
    private var fileURL: URL
    private var maxBytes: Int
    private var maxFiles: Int

    init(fileURL: URL, maxBytes: Int, maxFiles: Int, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.maxBytes = max(256 * 1024, maxBytes)
        self.maxFiles = max(1, maxFiles)
        self.fileManager = fileManager
    }

    func updateRotation(maxBytes: Int, maxFiles: Int) {
        self.maxBytes = max(256 * 1024, maxBytes)
        self.maxFiles = max(1, maxFiles)
    }

    func write(_ record: LogRecord) async {
        do {
            try ensureDirectory()
            try rotateIfNeeded(incomingApproxBytes: record.approxBytes)
            let line = try encodeJSONLine(record)
            try append(line)
        } catch {
            // Best-effort file output.
        }
    }

    func clear() throws {
        try ensureDirectory()
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.truncate(atOffset: 0)
        try handle.close()
        try fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: fileURL.path)
    }

    private func ensureDirectory() throws {
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: fileURL.path) {
            fileManager.createFile(atPath: fileURL.path, contents: Data())
        }
    }

    private func rotateIfNeeded(incomingApproxBytes: Int) throws {
        let size = (try? fileManager.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size + incomingApproxBytes > maxBytes else { return }

        for index in stride(from: maxFiles - 1, through: 1, by: -1) {
            let src = rotatedURL(index)
            let dst = rotatedURL(index + 1)
            if fileManager.fileExists(atPath: src.path) {
                try? fileManager.removeItem(at: dst)
                try? fileManager.moveItem(at: src, to: dst)
            }
        }

        let first = rotatedURL(1)
        try? fileManager.removeItem(at: first)
        if fileManager.fileExists(atPath: fileURL.path) {
            try? fileManager.moveItem(at: fileURL, to: first)
        }
        fileManager.createFile(atPath: fileURL.path, contents: Data())
    }

    private func rotatedURL(_ index: Int) -> URL {
        fileURL.appendingPathExtension(String(index))
    }

    private func encodeJSONLine(_ record: LogRecord) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(record)
        return data + Data([0x0A])
    }

    private func append(_ data: Data) throws {
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.close()
        try? fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: fileURL.path)
    }
}

private extension LogRecord {
    var approxBytes: Int {
        256 + message.utf8.count + metadata.count * 48
    }
}

extension LogValue {
    var displayString: String {
        switch self {
        case .string(let value): return value
        case .int(let value): return String(value)
        case .double(let value): return String(value)
        case .bool(let value): return value ? "true" : "false"
        case .redacted: return "***"
        }
    }
}

actor FluxLogger {
    static let shared = FluxLogger()

    private let subsystem: String
    private var config: LogConfig
    private let osSink: OSLogSink
    private let fileSink: RotatingFileSink
    private let memorySink: MemoryLogSink

    init(subsystem: String = Bundle.main.bundleIdentifier ?? "com.flux.Flux", config: LogConfig = LogConfig()) {
        self.subsystem = subsystem
        self.config = config

        self.osSink = OSLogSink(subsystem: subsystem)
        let logFileURL = FluxPaths.configDir()
            .appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent("flux.log", isDirectory: false)
        self.fileSink = RotatingFileSink(fileURL: logFileURL, maxBytes: config.fileMaxBytes, maxFiles: config.fileMaxFiles)
        self.memorySink = MemoryLogSink(capacity: config.memoryCapacity)
    }

    func debug(_ message: String, category: String = "Flux") async {
        await log(.debug, message, category: category)
    }

    func info(_ message: String, category: String = "Flux") async {
        await log(.info, message, category: category)
    }

    func warning(_ message: String, category: String = "Flux") async {
        await log(.warning, message, category: category)
    }

    func error(_ message: String, category: String = "Flux") async {
        await log(.error, message, category: category)
    }

    func log(_ level: FluxLogLevel, _ message: String, category: String = "Flux") async {
        await log(level, category: category, metadata: [:], message: message)
    }

    func log(
        _ level: FluxLogLevel,
        category: LogCategory = LogCategories.flux,
        metadata: [String: LogValue] = [:],
        message: @autoclosure @Sendable () -> String
    ) async {
        guard shouldLog(level, category: category) else { return }
        await route(level: level, category: category, metadata: metadata, message: message())
    }

    func updateConfig(_ config: LogConfig) async {
        self.config = config
        await memorySink.updateCapacity(config.memoryCapacity)
        await fileSink.updateRotation(maxBytes: config.fileMaxBytes, maxFiles: config.fileMaxFiles)
    }

    func stream() async -> AsyncStream<LogRecord> {
        await memorySink.stream()
    }

    func recentRecords() async -> [LogRecord] {
        await memorySink.recentRecords()
    }

    func clearAppLogs() async {
        await memorySink.clear()
        do {
            try await fileSink.clear()
        } catch {
            // Best-effort clear.
        }
    }

    private func shouldLog(_ level: FluxLogLevel, category: LogCategory) -> Bool {
        level >= config.minLevel(for: category)
    }

    private func route(level: FluxLogLevel, category: LogCategory, metadata: [String: LogValue], message: String) async {
        guard shouldLog(level, category: category) else { return }

        let sanitizedMessage = sanitize(message)
        let sanitizedMetadata = sanitizeMetadata(metadata)

        let record = LogRecord(
            id: UUID(),
            timestamp: .now,
            level: level,
            category: category,
            message: sanitizedMessage,
            metadata: sanitizedMetadata
        )

        if config.enableOSLog {
            await osSink.write(record)
        }
        if config.enableFile {
            await fileSink.write(record)
        }
        if config.enableMemory {
            await memorySink.write(record)
        }
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

    private func sanitizeMetadata(_ metadata: [String: LogValue]) -> [String: LogValue] {
        guard metadata.isEmpty == false else { return [:] }

        let sensitiveKeys: Set<String> = [
            "authorization",
            "access_token",
            "refresh_token",
            "api_key",
            "apikey",
            "token",
        ]

        var next: [String: LogValue] = [:]
        next.reserveCapacity(metadata.count)
        for (key, value) in metadata {
            if sensitiveKeys.contains(key.lowercased()) {
                next[key] = .redacted
                continue
            }
            switch value {
            case .string(let string):
                next[key] = .string(sanitize(string))
            default:
                next[key] = value
            }
        }
        return next
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
