import Foundation

struct CoreError: Error, LocalizedError, Codable, Sendable, Equatable {
    var code: CoreErrorCode
    var message: String
    var details: String?
    var recoverySuggestion: String?

    init(
        code: CoreErrorCode,
        message: String,
        details: String? = nil,
        recoverySuggestion: String? = nil
    ) {
        self.code = code
        self.message = message
        self.details = details
        self.recoverySuggestion = recoverySuggestion
    }

    var errorDescription: String? { message }
    var failureReason: String? { details }
}
