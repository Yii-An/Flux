import Foundation

struct HostArchDetector: Sendable {
    static func currentHostArch() throws -> HostArch {
        if let arch = HostArch(unameMachine: unameMachine()) {
            return arch
        }
        throw CoreError(code: .parseError, message: "Unsupported host architecture", details: "uname -m returned: \(unameMachine())")
    }

    static func isRunningUnderRosetta() -> Bool {
        guard HostArch(unameMachine: unameMachine()) == .arm64 else { return false }
        return sysctlInt("sysctl.proc_translated") == 1
    }

    static func isRosettaAvailable() -> Bool {
        guard HostArch(unameMachine: unameMachine()) == .arm64 else { return false }

        if isRunningUnderRosetta() {
            return true
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/arch")
        process.arguments = ["-x86_64", "/usr/bin/true"]
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func unameMachine() -> String {
        var info = utsname()
        uname(&info)
        let capacity = MemoryLayout.size(ofValue: info.machine)
        return withUnsafePointer(to: &info.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: capacity) { ptr in
                String(cString: ptr)
            }
        }
    }

    private static func sysctlInt(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let result = name.withCString { namePtr in
            sysctlbyname(namePtr, &value, &size, nil, 0)
        }
        guard result == 0 else { return nil }
        return value
    }
}
