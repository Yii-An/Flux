import Cocoa

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarController: MenuBarController?
    private var terminationInProgress = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBarController = MenuBarController()
        WindowPolicyManager.shared.configure(showInDock: false)

        Task {
            let settings = (try? await SettingsStore.shared.load()) ?? .default
            LanguageManager.shared.setLanguage(settings.language)
            WindowPolicyManager.shared.configure(showInDock: settings.showInDock)
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
            WindowPolicyManager.shared.openMainWindow()
        }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let forcedQuit = WindowPolicyManager.shared.consumeForceQuitRequested()
        if !forcedQuit, WindowPolicyManager.shared.isMainWindowVisible() {
            // Cmd+Q behavior: hide the main window, keep running in menu bar.
            WindowPolicyManager.shared.hideMainWindow()
            return .terminateCancel
        }

        guard !terminationInProgress else { return .terminateLater }
        terminationInProgress = true

        // Immediate user feedback: hide windows right away.
        for window in sender.windows {
            window.orderOut(nil)
        }
        sender.hide(nil)

        // Stop core asynchronously, then allow termination.
        Task {
            await CoreOrchestrator.shared.stop()
            await MainActor.run {
                sender.reply(toApplicationShouldTerminate: true)
            }
        }

        return .terminateLater
    }
}
