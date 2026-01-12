import Foundation
import ServiceManagement

actor LaunchAtLoginManager {
    static let shared = LaunchAtLoginManager()

    func isEnabled() -> Bool {
        let status = SMAppService.mainApp.status
        return status == .enabled || status == .requiresApproval
    }

    func enable() throws {
        let status = SMAppService.mainApp.status
        if status == .enabled || status == .requiresApproval {
            return
        }
        try SMAppService.mainApp.register()
    }

    func disable() throws {
        let status = SMAppService.mainApp.status
        if status == .notRegistered || status == .notFound {
            return
        }
        try SMAppService.mainApp.unregister()
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try enable()
        } else {
            try disable()
        }
    }
}

