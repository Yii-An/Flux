import Foundation
import UserNotifications
import os.log

@MainActor
final class NotificationService: ObservableObject {
    static let shared = NotificationService()

    private let logger = Logger(subsystem: "com.flux.app", category: "Notifications")
    @Published private(set) var isAuthorized = false

    private init() {}

    func requestAuthorization() async {
        let center = UNUserNotificationCenter.current()

        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            isAuthorized = granted
            logger.info("Notification authorization: \(granted)")
        } catch {
            logger.error("Failed to request notification authorization: \(error.localizedDescription)")
        }
    }

    func sendNotification(
        title: String,
        body: String,
        identifier: String = UUID().uuidString,
        categoryIdentifier: String? = nil
    ) {
        guard isAuthorized else {
            logger.warning("Notifications not authorized, skipping: \(title)")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        if let category = categoryIdentifier {
            content.categoryIdentifier = category
        }

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil // Deliver immediately
        )

        UNUserNotificationCenter.current().add(request) { [weak self] error in
            if let error = error {
                self?.logger.error("Failed to send notification: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Convenience Methods

    func notifyProcessStarted(port: Int) {
        sendNotification(
            title: "CLIProxyAPI 已启动",
            body: "服务正在端口 \(port) 上运行",
            identifier: "process-started"
        )
    }

    func notifyProcessStopped() {
        sendNotification(
            title: "CLIProxyAPI 已停止",
            body: "代理服务已停止运行",
            identifier: "process-stopped"
        )
    }

    func notifyProcessFailed(reason: String) {
        sendNotification(
            title: "CLIProxyAPI 启动失败",
            body: reason,
            identifier: "process-failed"
        )
    }

    func notifyHealthCheckFailed() {
        sendNotification(
            title: "健康检查失败",
            body: "无法连接到 CLIProxyAPI 管理接口",
            identifier: "health-check-failed"
        )
    }
}
