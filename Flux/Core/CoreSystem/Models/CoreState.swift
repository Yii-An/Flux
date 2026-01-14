import Foundation

struct CoreState: Codable, Sendable, Equatable {
    var schemaVersion: Int
    var activeVersion: String?
    var lastKnownGoodVersion: String?
    var consecutiveHealthFailures: Int
    var lastUpgradeAttempt: UpgradeAttempt?

    init(
        schemaVersion: Int = 1,
        activeVersion: String? = nil,
        lastKnownGoodVersion: String? = nil,
        consecutiveHealthFailures: Int = 0,
        lastUpgradeAttempt: UpgradeAttempt? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.activeVersion = activeVersion
        self.lastKnownGoodVersion = lastKnownGoodVersion
        self.consecutiveHealthFailures = consecutiveHealthFailures
        self.lastUpgradeAttempt = lastUpgradeAttempt
    }
}

struct UpgradeAttempt: Codable, Sendable, Equatable {
    var version: String
    var startedAt: Date
    var finishedAt: Date?
    var result: String?
    var errorCode: CoreErrorCode?

    init(
        version: String,
        startedAt: Date,
        finishedAt: Date? = nil,
        result: String? = nil,
        errorCode: CoreErrorCode? = nil
    ) {
        self.version = version
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.result = result
        self.errorCode = errorCode
    }
}

enum CoreLifecycleState: Codable, Sendable, Equatable {
    case idle
    case starting(targetVersion: String?, port: UInt16)
    case running(activeVersion: String, pid: Int32, port: UInt16, startedAt: Date)
    case stopping
    case installing(version: String, phase: String?)
    case testing(version: String, pid: Int32, port: UInt16, startedAt: Date)
    case promoting(version: String)
    case rollingBack(from: String, to: String)
    case error(CoreError)

    private enum Kind: String, Codable {
        case idle
        case starting
        case running
        case stopping
        case installing
        case testing
        case promoting
        case rollingBack
        case error
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case targetVersion
        case activeVersion
        case pid
        case port
        case startedAt
        case version
        case phase
        case from
        case to
        case error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)

        switch kind {
        case .idle:
            self = .idle
        case .starting:
            self = .starting(
                targetVersion: try container.decodeIfPresent(String.self, forKey: .targetVersion),
                port: try container.decode(UInt16.self, forKey: .port)
            )
        case .running:
            self = .running(
                activeVersion: try container.decode(String.self, forKey: .activeVersion),
                pid: try container.decode(Int32.self, forKey: .pid),
                port: try container.decode(UInt16.self, forKey: .port),
                startedAt: try container.decode(Date.self, forKey: .startedAt)
            )
        case .stopping:
            self = .stopping
        case .installing:
            self = .installing(
                version: try container.decode(String.self, forKey: .version),
                phase: try container.decodeIfPresent(String.self, forKey: .phase)
            )
        case .testing:
            self = .testing(
                version: try container.decode(String.self, forKey: .version),
                pid: try container.decode(Int32.self, forKey: .pid),
                port: try container.decode(UInt16.self, forKey: .port),
                startedAt: try container.decode(Date.self, forKey: .startedAt)
            )
        case .promoting:
            self = .promoting(version: try container.decode(String.self, forKey: .version))
        case .rollingBack:
            self = .rollingBack(
                from: try container.decode(String.self, forKey: .from),
                to: try container.decode(String.self, forKey: .to)
            )
        case .error:
            self = .error(try container.decode(CoreError.self, forKey: .error))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .idle:
            try container.encode(Kind.idle, forKey: .kind)
        case .starting(let targetVersion, let port):
            try container.encode(Kind.starting, forKey: .kind)
            try container.encodeIfPresent(targetVersion, forKey: .targetVersion)
            try container.encode(port, forKey: .port)
        case .running(let activeVersion, let pid, let port, let startedAt):
            try container.encode(Kind.running, forKey: .kind)
            try container.encode(activeVersion, forKey: .activeVersion)
            try container.encode(pid, forKey: .pid)
            try container.encode(port, forKey: .port)
            try container.encode(startedAt, forKey: .startedAt)
        case .stopping:
            try container.encode(Kind.stopping, forKey: .kind)
        case .installing(let version, let phase):
            try container.encode(Kind.installing, forKey: .kind)
            try container.encode(version, forKey: .version)
            try container.encodeIfPresent(phase, forKey: .phase)
        case .testing(let version, let pid, let port, let startedAt):
            try container.encode(Kind.testing, forKey: .kind)
            try container.encode(version, forKey: .version)
            try container.encode(pid, forKey: .pid)
            try container.encode(port, forKey: .port)
            try container.encode(startedAt, forKey: .startedAt)
        case .promoting(let version):
            try container.encode(Kind.promoting, forKey: .kind)
            try container.encode(version, forKey: .version)
        case .rollingBack(let from, let to):
            try container.encode(Kind.rollingBack, forKey: .kind)
            try container.encode(from, forKey: .from)
            try container.encode(to, forKey: .to)
        case .error(let error):
            try container.encode(Kind.error, forKey: .kind)
            try container.encode(error, forKey: .error)
        }
    }
}

