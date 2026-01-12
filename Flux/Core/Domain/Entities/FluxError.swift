import Foundation

enum FluxErrorCode: String, Codable, Sendable {
    case fileMissing
    case parseError
    case networkError
    case authError
    case rateLimited
    case unsupported
    case coreStartFailed
    case coreStopFailed
    case unknown
}

struct FluxError: Error, Codable, Sendable, Hashable, LocalizedError {
    var code: FluxErrorCode
    var message: String
    var details: String?
    var recoverySuggestion: String?

    init(code: FluxErrorCode, message: String, details: String? = nil, recoverySuggestion: String? = nil) {
        self.code = code
        self.message = message
        self.details = details
        self.recoverySuggestion = recoverySuggestion
    }

    var errorDescription: String? { message }
    var failureReason: String? { details }
}
