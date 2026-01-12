import Foundation

actor SettingsStore {
    struct SettingsFileV1: Codable, Sendable {
        var schemaVersion: Int = 1
        var settings: AppSettings

        init(settings: AppSettings) {
            self.settings = settings
        }
    }

    static let shared = SettingsStore()

    private let fileManager = FileManager.default
    private let decoder = JSONDecoder()

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private init() {}

    func load() async throws -> AppSettings {
        try FluxPaths.ensureConfigDirExists()

        let url = FluxPaths.settingsURL()
        guard fileManager.fileExists(atPath: url.path) else {
            syncLanguage(AppSettings.default.language)
            return AppSettings.`default`
        }

        do {
            let data = try Data(contentsOf: url)
            let file = try decoder.decode(SettingsFileV1.self, from: data)
            guard file.schemaVersion == 1 else {
                throw FluxError(
                    code: .unsupported,
                    message: "Unsupported settings schema version: \(file.schemaVersion)",
                    recoverySuggestion: "Please migrate or delete ~/.config/flux/settings.json"
                )
            }
            syncLanguage(file.settings.language)
            return file.settings
        } catch let error as FluxError {
            throw error
        } catch {
            throw FluxError(
                code: .parseError,
                message: "Failed to parse settings.json",
                details: String(describing: error),
                recoverySuggestion: "Fix the JSON format or delete ~/.config/flux/settings.json"
            )
        }
    }

    func save(_ settings: AppSettings) async throws {
        try FluxPaths.ensureConfigDirExists()

        let url = FluxPaths.settingsURL()
        let file = SettingsFileV1(settings: settings)
        let data = try encoder.encode(file)

        try atomicWrite(data: data, to: url)
        try fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: url.path)

        syncLanguage(settings.language)
    }

    private func atomicWrite(data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        let tmpURL = dir.appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)", isDirectory: false)

        var completed = false
        defer {
            if !completed {
                try? fileManager.removeItem(at: tmpURL)
            }
        }

        try data.write(to: tmpURL, options: [.atomic])

        if fileManager.fileExists(atPath: url.path) {
            _ = try fileManager.replaceItemAt(url, withItemAt: tmpURL)
        } else {
            try fileManager.moveItem(at: tmpURL, to: url)
        }
        completed = true
    }

    private func syncLanguage(_ language: AppLanguage) {
        UserDefaults.standard.set(language.rawValue, forKey: "appLanguage")
    }
}
