import Cocoa

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarController: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBarController = MenuBarController()

        Task {
            let settings = (try? await SettingsStore.shared.load()) ?? .default
            LanguageManager.shared.setLanguage(settings.language)
            await UpdateService.shared.applySettings(settings)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}
