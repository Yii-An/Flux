import Foundation

struct CoreVersionMetadata: Codable, Sendable, Equatable {
    var schemaVersion: Int
    var version: String
    var installedAt: Date
    var validatedAt: Date?

    var source: Source
    var binary: Binary

    init(
        schemaVersion: Int = 1,
        version: String,
        installedAt: Date,
        validatedAt: Date? = nil,
        source: Source,
        binary: Binary
    ) {
        self.schemaVersion = schemaVersion
        self.version = version
        self.installedAt = installedAt
        self.validatedAt = validatedAt
        self.source = source
        self.binary = binary
    }

    struct Source: Codable, Sendable, Equatable {
        var repo: String
        var tag: String
        var assetName: String
        var assetURL: URL?
        var assetSHA256: String?

        init(repo: String, tag: String, assetName: String, assetURL: URL? = nil, assetSHA256: String? = nil) {
            self.repo = repo
            self.tag = tag
            self.assetName = assetName
            self.assetURL = assetURL
            self.assetSHA256 = assetSHA256
        }
    }

    struct Binary: Codable, Sendable, Equatable {
        var nameInArchive: String?
        var finalName: String
        var sha256: String
        var arch: HostArch?
        var format: String
        var isExecutable: Bool

        init(
            nameInArchive: String? = nil,
            finalName: String = "CLIProxyAPI",
            sha256: String,
            arch: HostArch? = nil,
            format: String = "macho",
            isExecutable: Bool = true
        ) {
            self.nameInArchive = nameInArchive
            self.finalName = finalName
            self.sha256 = sha256
            self.arch = arch
            self.format = format
            self.isExecutable = isExecutable
        }
    }
}

