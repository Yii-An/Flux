import Foundation

enum ViewState<Value: Sendable>: Sendable {
    case idle
    case loading
    case loaded(Value)
    case failed(FluxError)

    var isLoading: Bool {
        if case .loading = self { true } else { false }
    }

    var value: Value? {
        if case let .loaded(value) = self { value } else { nil }
    }

    var error: FluxError? {
        if case let .failed(error) = self { error } else { nil }
    }
}
