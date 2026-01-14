import AppKit
import Foundation
import SwiftUI

/// Centralizes window visibility policy, activationPolicy switching, and quit behavior.
@MainActor
final class WindowPolicyManager {
    static let shared = WindowPolicyManager()

    private var showInDock: Bool = false
    private var forceQuitRequested = false
    private var forceRegularUntil: Date?

    private var openWindowAction: OpenWindowAction?
    private var bringToFrontTask: Task<Void, Never>?
    private var pendingNavigationPage: NavigationPage?
    private var fallbackMainWindow: NSWindow?

    private var observers: [Any] = []

    private init() {
        installObservers()
        applyActivationPolicy()
    }

    func configure(showInDock: Bool) {
        self.showInDock = showInDock
        applyActivationPolicy()
    }

    func updateShowInDock(_ value: Bool) {
        showInDock = value
        applyActivationPolicy()
    }

    func registerOpenWindow(_ action: OpenWindowAction) {
        openWindowAction = action
    }

    func requestQuit() {
        forceQuitRequested = true
        NSApp.terminate(nil)
    }

    func consumeForceQuitRequested() -> Bool {
        let value = forceQuitRequested
        forceQuitRequested = false
        return value
    }

    func openMainWindow(navigateTo page: NavigationPage? = nil) {
        if let page {
            pendingNavigationPage = page
        }

        if !showInDock {
            // Prevent observers from flipping back to `.accessory` while the window is still being created/shown.
            forceRegularUntil = Date().addingTimeInterval(1.0)
            NSApp.setActivationPolicy(.regular)
        }

        NSApp.unhide(nil)
        activateApp()

        if let window = findMainWindow() {
            present(window: window)
            flushPendingNavigationIfPossible()
            applyActivationPolicy()
            return
        }

        if let openWindowAction {
            openWindowAction(id: "main")
            bringMainWindowToFrontWithRetry()
            return
        }

        createFallbackMainWindowIfNeeded()
        if let window = findMainWindow() {
            present(window: window)
            flushPendingNavigationIfPossible()
        }
        applyActivationPolicy()
    }

    /// Used for Cmd+Q override when main window is visible.
    /// "Closes" main window by hiding it, keeping the app running in menu bar.
    func hideMainWindow() {
        if let window = findMainWindow(), window.isVisible {
            window.orderOut(nil)
        } else {
            for window in NSApplication.shared.windows where window.level == .normal && window.isVisible {
                window.orderOut(nil)
            }
        }
        applyActivationPolicy()
    }

    func isMainWindowVisible() -> Bool {
        if let window = findMainWindow() {
            return window.isVisible && !window.isMiniaturized && !NSApp.isHidden
        }
        return isAnyPrimaryWindowVisible() && !NSApp.isHidden
    }

    // MARK: - Private

    private func findMainWindow() -> NSWindow? {
        let windows = NSApplication.shared.windows

        // Prefer explicit scene/window IDs when available.
        if let byIdentifier = windows.first(where: { $0.identifier?.rawValue == "main" }) {
            return byIdentifier
        }

        // Fallback: match the app's main window title if it exists.
        if let byTitle = windows.first(where: { $0.title == "Flux" && $0.level == .normal && $0.canBecomeKey }) {
            return byTitle
        }

        // Heuristic fallback: pick a normal-level key-capable window (avoids popovers/panels).
        return windows.first(where: { $0.level == .normal && $0.canBecomeKey })
    }

    private func bringMainWindowToFrontWithRetry() {
        bringToFrontTask?.cancel()
        bringToFrontTask = Task { @MainActor in
            for _ in 0..<20 {
                if Task.isCancelled { return }
                if let window = findMainWindow() {
                    present(window: window)
                    flushPendingNavigationIfPossible()
                    applyActivationPolicy()
                    return
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }

            createFallbackMainWindowIfNeeded()
            if let window = findMainWindow() {
                present(window: window)
                flushPendingNavigationIfPossible()
            }
            applyActivationPolicy()
        }
    }

    private func flushPendingNavigationIfPossible() {
        guard let page = pendingNavigationPage else { return }
        pendingNavigationPage = nil
        FluxNavigation.navigate(to: page)
    }

    private func createFallbackMainWindowIfNeeded() {
        guard findMainWindow() == nil else { return }
        if let existing = fallbackMainWindow {
            present(window: existing)
            return
        }

        let initialPage = pendingNavigationPage ?? .dashboard
        let hostingController = NSHostingController(rootView: FluxRootContainerView(initialPage: initialPage))
        let window = NSWindow(contentViewController: hostingController)
        window.identifier = NSUserInterfaceItemIdentifier("main")
        window.title = "Flux"
        window.setContentSize(NSSize(width: 980, height: 720))
        window.center()
        fallbackMainWindow = window
        present(window: window)
    }

    private func activateApp() {
        NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        NSApp.activate(ignoringOtherApps: true)
    }

    private func present(window: NSWindow) {
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }

        // Avoid showing a non-activating window: explicitly activate first.
        activateApp()
        window.makeKeyAndOrderFront(nil)

        // If it's still not key (rare), activate again and retry.
        if !window.isKeyWindow {
            activateApp()
            window.makeKeyAndOrderFront(nil)
        }
    }

    private func isAnyPrimaryWindowVisible() -> Bool {
        NSApplication.shared.windows.contains(where: { $0.level == .normal && $0.isVisible && !$0.isMiniaturized })
    }

    private func isForceRegularActive() -> Bool {
        guard let until = forceRegularUntil else { return false }
        if until > Date() { return true }
        forceRegularUntil = nil
        return false
    }

    private func applyActivationPolicy() {
        let shouldBeRegular = showInDock || isAnyPrimaryWindowVisible() || isForceRegularActive()
        NSApp.setActivationPolicy(shouldBeRegular ? .regular : .accessory)
    }

    private func installObservers() {
        let center = NotificationCenter.default

        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] _ in
            self?.applyActivationPolicy()
        })
        observers.append(center.addObserver(forName: NSWindow.didMiniaturizeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.applyActivationPolicy()
        })
        observers.append(center.addObserver(forName: NSWindow.didDeminiaturizeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.applyActivationPolicy()
        })
        observers.append(center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main) { [weak self] _ in
            self?.applyActivationPolicy()
        })
        observers.append(center.addObserver(forName: NSApplication.didHideNotification, object: nil, queue: .main) { [weak self] _ in
            self?.applyActivationPolicy()
        })
        observers.append(center.addObserver(forName: NSApplication.didUnhideNotification, object: nil, queue: .main) { [weak self] _ in
            self?.applyActivationPolicy()
        })
    }
}
