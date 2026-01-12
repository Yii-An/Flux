import Foundation
import Observation

@MainActor
@Observable
final class LanguageManager {
    static let shared = LanguageManager()

    private(set) var currentLanguage: AppLanguage {
        didSet {
            guard oldValue != currentLanguage else { return }
            UserDefaults.standard.set(currentLanguage.rawValue, forKey: "appLanguage")
        }
    }

    var locale: Locale {
        switch currentLanguage {
        case .system:
            return .autoupdatingCurrent
        case .en, .zhHans:
            return Locale(identifier: currentLanguage.rawValue)
        }
    }

    var bundle: Bundle {
        switch currentLanguage {
        case .system:
            return .main
        case .en, .zhHans:
            guard let path = Bundle.main.path(forResource: currentLanguage.rawValue, ofType: "lproj"),
                  let bundle = Bundle(path: path)
            else {
                return .main
            }
            return bundle
        }
    }

    private init() {
        let saved = UserDefaults.standard.string(forKey: "appLanguage") ?? AppLanguage.system.rawValue
        self.currentLanguage = AppLanguage(rawValue: saved) ?? .system
    }

    func setLanguage(_ language: AppLanguage) {
        currentLanguage = language
    }

    func localized(_ key: String) -> String {
        NSLocalizedString(key, bundle: bundle, comment: "")
    }
}

extension String {
    @MainActor
    func localized() -> String {
        LanguageManager.shared.localized(self)
    }

    nonisolated func localizedStatic() -> String {
        let saved = UserDefaults.standard.string(forKey: "appLanguage") ?? AppLanguage.system.rawValue
        let language = AppLanguage(rawValue: saved) ?? .system

        if language == .system {
            return NSLocalizedString(self, bundle: .main, comment: "")
        }

        if let path = Bundle.main.path(forResource: language.rawValue, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            return NSLocalizedString(self, bundle: bundle, comment: "")
        }

        return NSLocalizedString(self, bundle: .main, comment: "")
    }
}

