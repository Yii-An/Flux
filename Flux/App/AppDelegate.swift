import Cocoa

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarController: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBarController = MenuBarController()
        NSApp.setActivationPolicy(.accessory)

        Task {
            let settings = (try? await SettingsStore.shared.load()) ?? .default
            LanguageManager.shared.setLanguage(settings.language)
            NSApp.setActivationPolicy(settings.showInDock ? .regular : .accessory)
            await FluxLogger.shared.updateConfig(settings.logConfig)
            await UpdateService.shared.applySettings(settings)
            await QuotaRefreshScheduler.shared.start(intervalSeconds: settings.refreshIntervalSeconds)
            await FluxLogger.shared.info("App launched", category: LogCategories.app)
            await FluxLogger.shared.log(.info, category: LogCategories.app, message: "App launched, triggering quota refresh")
            _ = await QuotaAggregator.shared.refreshAll(force: false)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if flag == false {
            if let window = sender.windows.first(where: { $0.title == "Flux" }) {
                if window.isMiniaturized {
                    window.deminiaturize(nil)
                }
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
            }
        }
        return true
    }
}
