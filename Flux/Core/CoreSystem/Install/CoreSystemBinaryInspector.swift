import Foundation

actor CoreSystemBinaryInspector {
    static let shared = CoreSystemBinaryInspector()

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Validates the given file is a Mach-O executable compatible with the current machine.
    /// Returns the architecture that will be used to execute it.
    func validateExecutable(at url: URL) throws -> HostArch {
        guard fileManager.fileExists(atPath: url.path) else {
            throw CoreError(code: .fileMissing, message: "Core binary not found", details: url.path)
        }

        guard (try isMachOFile(at: url)) else {
            throw CoreError(code: .coreBinaryInvalidFormat, message: "Core binary is not a Mach-O executable", details: url.lastPathComponent)
        }

        let hostArch = try HostArchDetector.currentHostArch()
        let supported = try supportedArchitectures(at: url)

        if supported.contains(hostArch) {
            return hostArch
        }

        if hostArch == .arm64, supported.contains(.x86_64) {
            if HostArchDetector.isRosettaAvailable() {
                return .x86_64
            }
            throw CoreError(code: .rosettaRequired, message: "Rosetta is required to run x86_64 core on Apple Silicon", details: url.lastPathComponent)
        }

        let supportedList = supported.map { $0.rawValue }.sorted().joined(separator: ",")
        throw CoreError(
            code: .coreBinaryArchMismatch,
            message: "Core binary architecture mismatch",
            details: "host=\(hostArch.rawValue) supported=\(supportedList)"
        )
    }

    func bestEffortAdhocCodesign(at url: URL) async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-f", "-s", "-", url.path]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return
        }
    }

    // MARK: - Mach-O inspection

    func isMachOFile(at url: URL) throws -> Bool {
        let magic = try readUInt32Prefix(at: url)
        return Self.isMachOMagic(magic)
    }

    private func supportedArchitectures(at url: URL) throws -> Set<HostArch> {
        let output = try lipoInfo(at: url).lowercased()

        var arches: Set<HostArch> = []

        if let range = output.range(of: "are:") {
            let tail = output[range.upperBound...]
            for token in tail.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "," }) {
                if let arch = Self.mapArchToken(String(token)) {
                    arches.insert(arch)
                }
            }
        } else if let range = output.range(of: "is architecture:") {
            let tail = output[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            let first = tail.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "," }).first.map(String.init)
            if let first, let arch = Self.mapArchToken(first) {
                arches.insert(arch)
            }
        }

        if !arches.isEmpty {
            return arches
        }

        // Fallback: if Mach-O magic looks valid but lipo output is unexpected.
        if try isMachOFile(at: url) {
            throw CoreError(code: .parseError, message: "Failed to parse lipo output", details: output)
        }

        throw CoreError(code: .coreBinaryInvalidFormat, message: "Core binary is not a Mach-O executable", details: url.lastPathComponent)
    }

    private func lipoInfo(at url: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/lipo")
        process.arguments = ["-info", url.path]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            throw CoreError(code: .coreBinaryInvalidFormat, message: "Failed to run lipo", details: String(describing: error))
        }

        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            throw CoreError(code: .coreBinaryInvalidFormat, message: "lipo failed", details: output.isEmpty ? "exit=\(process.terminationStatus)" : output)
        }

        return output
    }

    private func readUInt32Prefix(at url: URL) throws -> UInt32 {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let data = try handle.read(upToCount: 4) ?? Data()
        guard data.count == 4 else {
            throw CoreError(code: .coreBinaryInvalidFormat, message: "File too small to be Mach-O", details: url.lastPathComponent)
        }

        return data.withUnsafeBytes { ptr in
            ptr.loadUnaligned(as: UInt32.self)
        }
    }

    static func isMachOMagic(_ magic: UInt32) -> Bool {
        switch magic {
        case 0xFEEDFACE, 0xCEFAEDFE: // MH_MAGIC, MH_CIGAM
            return true
        case 0xFEEDFACF, 0xCFFAEDFE: // MH_MAGIC_64, MH_CIGAM_64
            return true
        case 0xCAFEBABE, 0xBEBAFECA: // FAT_MAGIC, FAT_CIGAM
            return true
        default:
            return false
        }
    }

    private static func mapArchToken(_ token: String) -> HostArch? {
        switch token.lowercased() {
        case "arm64", "arm64e":
            return .arm64
        case "x86_64":
            return .x86_64
        default:
            return nil
        }
    }
}
