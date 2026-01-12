import Foundation

#if canImport(Sparkle)
import AppKit
import Sparkle
#endif

actor UpdateService {
    static let shared = UpdateService()

    private init() {}

    func applySettings(_ settings: AppSettings) async {
        #if canImport(Sparkle)
        await SparkleHost.shared.applySettings(settings)
        #else
        _ = settings
        #endif
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) async {
        #if canImport(Sparkle)
        await SparkleHost.shared.setAutomaticallyChecksForUpdates(enabled)
        #else
        _ = enabled
        #endif
    }

    func checkForUpdates() async {
        #if canImport(Sparkle)
        await SparkleHost.shared.checkForUpdates()
        #endif
    }
}

#if canImport(Sparkle)
@MainActor
private final class SparkleHost {
    static let shared = SparkleHost()

    private var updaterController: SPUStandardUpdaterController?
    private var isInitialized: Bool = false

    private init() {}

    func applySettings(_ settings: AppSettings) {
        setAutomaticallyChecksForUpdates(settings.automaticallyChecksForUpdates)
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        initializeIfNeeded()
        updaterController?.updater.automaticallyChecksForUpdates = enabled
    }

    func checkForUpdates() {
        initializeIfNeeded()

        guard updaterController?.updater.canCheckForUpdates == true else {
            presentAlert(
                title: "Updates not configured".localizedStatic(),
                message: "SUFeedURL is missing or invalid. Configure an appcast feed URL to enable Sparkle updates.".localizedStatic()
            )
            return
        }

        updaterController?.updater.checkForUpdates()
    }

    private func initializeIfNeeded() {
        guard !isInitialized else { return }

        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        isInitialized = true
    }

    private func presentAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK".localizedStatic())
        alert.runModal()
    }
}
#endif
