import Foundation

extension LoadState where T: Collection {
    var count: Int? {
        if case .loaded(let items) = self {
            return items.count
        }
        return nil
    }

    var countText: String {
        if case .loaded(let items) = self {
            return "\(items.count)"
        }
        return "--"
    }
}

