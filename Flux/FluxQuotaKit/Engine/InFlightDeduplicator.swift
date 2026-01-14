import Foundation

actor InFlightDeduplicator {
    enum InFlightError: Error {
        case typeMismatch
    }

    private struct AnySendableBox: @unchecked Sendable {
        let value: Any
    }

    private var tasks: [String: Task<AnySendableBox, Error>] = [:]

    func run<T: Sendable>(
        key: String,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        if let existing = tasks[key] {
            let boxed = try await existing.value
            guard let value = boxed.value as? T else {
                throw InFlightError.typeMismatch
            }
            return value
        }

        let task = Task<AnySendableBox, Error> {
            AnySendableBox(value: try await operation())
        }
        tasks[key] = task

        defer { tasks[key] = nil }

        let boxed = try await task.value
        guard let value = boxed.value as? T else {
            throw InFlightError.typeMismatch
        }
        return value
    }
}
