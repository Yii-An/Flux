import Cocoa
import SwiftUI

@MainActor
	class MenuBarController: NSObject {
	    private var statusItem: NSStatusItem?
	    private var popover: NSPopover?
	    private let statusMenu = NSMenu()

    private let quotaAggregator: QuotaAggregator
    private let coreOrchestrator: CoreOrchestrator

    private var openItem: NSMenuItem?
    private var refreshQuotaItem: NSMenuItem?
    private var checkUpdatesItem: NSMenuItem?
    private var startCoreItem: NSMenuItem?
    private var stopCoreItem: NSMenuItem?
    private var quitItem: NSMenuItem?

    init(quotaAggregator: QuotaAggregator = .shared, coreOrchestrator: CoreOrchestrator = .shared) {
        self.quotaAggregator = quotaAggregator
        self.coreOrchestrator = coreOrchestrator
        super.init()
        setupStatusBar()
    }

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.title = "Flux"
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.action = #selector(statusBarButtonClicked(_:))
            button.target = self
        }

        setupMenu()
        setupPopover()
    }

    private func setupPopover() {
        popover = NSPopover()
        popover?.contentSize = NSSize(width: 300, height: 380)
        popover?.behavior = .transient

        let viewModel = MenuBarViewModel(quotaAggregator: quotaAggregator)
        popover?.contentViewController = NSHostingController(
            rootView: MenuBarPopoverView(
                viewModel: viewModel,
                onOpenMainWindow: { [weak self] in
                    self?.openMainWindow()
                },
                onOpenSettings: { [weak self] in
                    self?.openMainWindow(navigateTo: .settings)
                },
                onQuit: { [weak self] in
                    self?.quit()
                }
            )
        )
    }

    private func setupMenu() {
        statusMenu.autoenablesItems = false

        let openItem = NSMenuItem(title: "", action: #selector(openFlux), keyEquivalent: "")
        openItem.target = self
        self.openItem = openItem

        let refreshQuotaItem = NSMenuItem(title: "", action: #selector(refreshQuota), keyEquivalent: "r")
        refreshQuotaItem.keyEquivalentModifierMask = [.command]
        refreshQuotaItem.target = self
        self.refreshQuotaItem = refreshQuotaItem

        let checkUpdatesItem = NSMenuItem(title: "", action: #selector(checkForUpdates), keyEquivalent: "")
        checkUpdatesItem.target = self
        self.checkUpdatesItem = checkUpdatesItem

        let startCoreItem = NSMenuItem(title: "", action: #selector(startCore), keyEquivalent: "")
        startCoreItem.target = self
        self.startCoreItem = startCoreItem

        let stopCoreItem = NSMenuItem(title: "", action: #selector(stopCore), keyEquivalent: "")
        stopCoreItem.target = self
        self.stopCoreItem = stopCoreItem

        let quitItem = NSMenuItem(title: "", action: #selector(quit), keyEquivalent: "q")
        quitItem.keyEquivalentModifierMask = [.command]
        quitItem.target = self
        self.quitItem = quitItem

        statusMenu.addItem(openItem)
        statusMenu.addItem(.separator())
        statusMenu.addItem(refreshQuotaItem)
        statusMenu.addItem(checkUpdatesItem)
        statusMenu.addItem(.separator())
        statusMenu.addItem(startCoreItem)
        statusMenu.addItem(stopCoreItem)
        statusMenu.addItem(.separator())
        statusMenu.addItem(quitItem)

        updateMenuTitles()
    }

    @objc private func statusBarButtonClicked(_ sender: Any?) {
        guard let button = statusItem?.button, let popover = popover else { return }

        if let event = NSApp.currentEvent, event.type == .rightMouseUp {
            showMenu(for: button)
            return
        }

        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func showMenu(for button: NSStatusBarButton) {
        updateMenuTitles()
        statusItem?.menu = statusMenu
        button.performClick(nil)
        statusItem?.menu = nil
    }

    private func updateMenuTitles() {
        openItem?.title = "Open Flux".localizedStatic()
        refreshQuotaItem?.title = "Refresh Quota".localizedStatic()
        checkUpdatesItem?.title = "Check for Updates…".localizedStatic()
        startCoreItem?.title = "Start Core".localizedStatic()
        stopCoreItem?.title = "Stop Core".localizedStatic()
        quitItem?.title = "Quit Flux".localizedStatic()
    }

    @objc private func openFlux() {
        openMainWindow()
    }

	    private func openMainWindow(navigateTo page: NavigationPage? = nil) {
	        popover?.performClose(nil)
	        WindowPolicyManager.shared.openMainWindow(navigateTo: page)
	    }

    @objc private func refreshQuota() {
        Task { [quotaAggregator] in
            _ = await quotaAggregator.refreshAll()
        }
    }

    @objc private func startCore() {
        Task { [coreOrchestrator] in
            await coreOrchestrator.start()
        }
    }

    @objc private func stopCore() {
        Task { [coreOrchestrator] in
            await coreOrchestrator.stop()
        }
    }

    @objc private func checkForUpdates() {
        Task { @MainActor in
            await UpdateService.shared.checkForUpdates()
        }
    }

    @objc private func quit() {
        WindowPolicyManager.shared.requestQuit()
    }
}
