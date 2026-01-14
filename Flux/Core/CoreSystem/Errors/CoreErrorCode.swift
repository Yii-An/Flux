import Foundation

enum CoreErrorCode: String, Codable, Sendable {
    case unknown

    // Network / GitHub
    case networkError
    case rateLimited
    case parseError
    case cacheCorrupted
    case webFetchFailed
    case htmlParseError

    // Release / Asset
    case noCompatibleAsset
    case unsupportedAssetFormat

    // Download / IO
    case downloadFailed
    case fileWriteFailed
    case fileMissing
    case permissionDenied

    // Checksum
    case checksumMissing
    case checksumMismatch

    // Extract / Security
    case invalidArchive
    case binaryNotFoundInArchive
    case pathTraversalDetected
    case symlinkEscapeDetected

    // Binary validation
    case coreBinaryInvalidFormat
    case coreBinaryArchMismatch
    case rosettaRequired

    // Run / Health
    case portInUse
    case coreStartFailed
    case coreStartTimeout
    case dryRunFailed
    case healthCheckFailed

    // Promote / Rollback / State
    case promoteFailed
    case rollbackFailed
    case cannotDeleteCurrentVersion
}
