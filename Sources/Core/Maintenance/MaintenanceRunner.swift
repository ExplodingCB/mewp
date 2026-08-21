import Foundation
import AppKit
import Darwin.Mach

enum MaintenanceOperation: String, CaseIterable, Identifiable, Sendable {
    case flushDNS
    case purgeFileCache
    case rebuildSpotlight
    case thinSnapshots

    var id: String { rawValue }

    var name: String {
        switch self {
        case .flushDNS: return "Flush DNS cache"
        case .purgeFileCache: return "Purge file cache"
        case .rebuildSpotlight: return "Rebuild Spotlight index"
        case .thinSnapshots: return "Thin local Time Machine snapshots"
        }
    }

    var detail: String {
        switch self {
        case .flushDNS:
            return "Clears cached DNS answers and restarts the responder. Use this when name lookups are stale or failing."
        case .purgeFileCache:
            return "Drops reclaimable disk-file cache from RAM. Apps and anonymous memory are not cleared, and the cache will fill again as files are read."
        case .rebuildSpotlight:
            return "Erases the startup disk's Spotlight index and starts a fresh index. Search results may be incomplete while it rebuilds."
        case .thinSnapshots:
            return "Asks Time Machine to reclaim up to 10 GB from local snapshots at the highest urgency."
        }
    }

    var systemImage: String {
        switch self {
        case .flushDNS: return "network"
        case .purgeFileCache: return "memorychip"
        case .rebuildSpotlight: return "magnifyingglass"
        case .thinSnapshots: return "clock.arrow.circlepath"
        }
    }

    /// Commands are fixed and contain no user-controlled values.
    var shellCommand: String {
        switch self {
        case .flushDNS:
            return "/usr/bin/dscacheutil -flushcache && /usr/bin/killall -HUP mDNSResponder"
        case .purgeFileCache:
            return "/usr/sbin/purge"
        case .rebuildSpotlight:
            return "/usr/bin/mdutil -E /"
        case .thinSnapshots:
            return "/usr/bin/tmutil thinlocalsnapshots / 10000000000 4"
        }
    }
}

struct MaintenanceResult: Sendable {
    var succeeded: Bool
    var message: String
}

enum MaintenanceRunner {
    /// Uses macOS's per-action administrator prompt. A persistent root daemon
    /// under ad hoc signing cannot provide a strong caller identity guarantee.
    static func run(_ operation: MaintenanceOperation) -> MaintenanceResult {
        let escaped = operation.shellCommand
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with administrator privileges"
        guard let script = NSAppleScript(source: source) else {
            return MaintenanceResult(succeeded: false, message: "Could not create the administrator request.")
        }

        var details: NSDictionary?
        let response = script.executeAndReturnError(&details)
        if let details {
            let message = (details[NSAppleScript.errorMessage] as? String)
                ?? "The maintenance command failed."
            return MaintenanceResult(succeeded: false, message: message)
        }

        let output = response.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        return MaintenanceResult(
            succeeded: true,
            message: output?.isEmpty == false ? output! : "Completed."
        )
    }

    static func setLowPowerMode(enabled: Bool) -> MaintenanceResult {
        let value = enabled ? "1" : "0"
        return runAdministratorCommand(
            "/usr/bin/pmset -b lowpowermode \(value)",
            successMessage: enabled ? "Low Power Mode enabled on battery." : "Low Power Mode disabled on battery."
        )
    }

    static func runAdministratorCommand(
        _ command: String,
        successMessage: String
    ) -> MaintenanceResult {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with administrator privileges"
        guard let script = NSAppleScript(source: source) else {
            return MaintenanceResult(succeeded: false, message: "Could not create the administrator request.")
        }

        var details: NSDictionary?
        _ = script.executeAndReturnError(&details)
        if let details {
            return MaintenanceResult(
                succeeded: false,
                message: (details[NSAppleScript.errorMessage] as? String) ?? "The command failed."
            )
        }
        return MaintenanceResult(succeeded: true, message: successMessage)
    }

    static func trashAdministratorItems(_ urls: [URL]) -> MaintenanceResult {
        guard !urls.isEmpty else {
            return MaintenanceResult(succeeded: true, message: "No administrator items selected.")
        }
        let allowedRoots = [
            "/Library/Application Support/",
            "/Library/Caches/",
            "/Library/Logs/",
            "/Library/LaunchAgents/",
            "/Library/LaunchDaemons/",
            "/Library/PrivilegedHelperTools/",
        ]
        let safeURLs = urls.filter { url in
            let path = url.standardizedFileURL.path
            return allowedRoots.contains { path.hasPrefix($0) }
        }
        guard safeURLs.count == urls.count else {
            return MaintenanceResult(
                succeeded: false,
                message: "A system item was outside the reviewed locations."
            )
        }

        let destination = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".Trash")
            .appendingPathComponent("CleanMyMewp Admin Items \(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        } catch {
            return MaintenanceResult(succeeded: false, message: "Could not create a Trash destination.")
        }

        let moves = safeURLs.map { url in
            let renamed = destination.appendingPathComponent(
                UUID().uuidString + "-" + url.lastPathComponent
            )
            return "/bin/mv \(shellQuote(url.path)) \(shellQuote(renamed.path))"
        }
        let owner = "\(getuid()):\(getgid())"
        let command = (moves + ["/usr/sbin/chown -R \(owner) \(shellQuote(destination.path))"])
            .joined(separator: " && ")
        return runAdministratorCommand(
            command,
            successMessage: "Moved reviewed system items to Trash."
        )
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

struct MemorySnapshot: Sendable {
    var physical: UInt64
    var wired: UInt64
    var compressed: UInt64
    var active: UInt64
    var inactive: UInt64
    var free: UInt64
    var speculative: UInt64
    var purgeable: UInt64

    static func current() -> MemorySnapshot? {
        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else { return nil }

        var statistics = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let status = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }

        let bytes: (UInt64) -> UInt64 = { $0 * UInt64(pageSize) }
        return MemorySnapshot(
            physical: ProcessInfo.processInfo.physicalMemory,
            wired: bytes(UInt64(statistics.wire_count)),
            compressed: bytes(UInt64(statistics.compressor_page_count)),
            active: bytes(UInt64(statistics.active_count)),
            inactive: bytes(UInt64(statistics.inactive_count)),
            free: bytes(UInt64(statistics.free_count)),
            speculative: bytes(UInt64(statistics.speculative_count)),
            purgeable: bytes(UInt64(statistics.purgeable_count))
        )
    }
}
