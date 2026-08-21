import Foundation
import IOKit
import IOKit.ps

struct CommandOutput: Sendable {
    var status: Int32
    var stdout: String
    var stderr: String
}

/// Mutable storage a background pipe reader can fill while the caller blocks on the
/// dispatch group that publishes it.
private final class DataBox: @unchecked Sendable {
    var data = Data()
}

/// Unit tests drive the engines synchronously on XCTest's main thread, which is fine —
/// there is no view graph to stall. Only the app is held to the off-main-thread rule.
private let runningUnderXCTest: Bool = {
    let environment = ProcessInfo.processInfo.environment
    return environment["XCTestConfigurationFilePath"] != nil
        || environment["XCTestBundlePath"] != nil
        || environment["XCTestSessionIdentifier"] != nil
}()

/// Minimal mutex box. CPU percentage is a delta against the previous sample, so the
/// tick counters have to persist between calls that may arrive on different threads.
private final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let mutex = NSLock()

    init(_ value: Value) { self.value = value }

    func withLock<Result>(_ body: (inout Value) -> Result) -> Result {
        mutex.lock()
        defer { mutex.unlock() }
        return body(&value)
    }
}

/// Debug-only guard for the blocking subprocess helpers below.
///
/// Calling these from the main thread is what produced the AttributeGraph abort this
/// module used to crash with: the old `Process.waitUntilExit()` ran the main run loop
/// mid-view-update. The wait no longer touches the run loop, so a main-thread call now
/// only stalls the UI — still a bug, and this catches it during development.
private func assertOffMainThread(_ function: StaticString) {
    assert(
        runningUnderXCTest || !Thread.isMainThread,
        "\(function) blocks the calling thread; run it off the main thread."
    )
}

enum SystemCommand {
    /// Runs a command to completion and returns its output.
    ///
    /// This deliberately avoids `Process.waitUntilExit()`. That call *runs the current
    /// run loop* while it waits, so on the main thread it re-enters SwiftUI's run-loop
    /// observer in the middle of a view update, which trips an AttributeGraph
    /// reentrancy precondition and aborts the process. Waiting on a semaphore signalled
    /// from `terminationHandler` blocks the thread without touching the run loop.
    ///
    /// It still blocks, so callers must stay off the main thread — the assertion below
    /// catches regressions in debug builds.
    static func run(_ executable: String, arguments: [String]) -> CommandOutput {
        assertOffMainThread("SystemCommand.run")

        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = errors

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            return CommandOutput(status: -1, stdout: "", stderr: error.localizedDescription)
        }

        // Drain stderr concurrently. Reading the pipes one after the other deadlocks if
        // the child fills the 64 KB buffer of the one we are not reading yet — `ps -A`
        // output on a busy Mac gets close.
        let errorBox = DataBox()
        let draining = DispatchGroup()
        DispatchQueue.global(qos: .userInitiated).async(group: draining) {
            errorBox.data = errors.fileHandleForReading.readDataToEndOfFile()
        }
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        draining.wait()
        exited.wait()

        return CommandOutput(
            status: process.terminationStatus,
            stdout: String(decoding: outputData, as: UTF8.self),
            stderr: String(decoding: errorBox.data, as: UTF8.self)
        )
    }

    /// Runs a command only for its exit status, discarding output.
    static func status(_ executable: String, arguments: [String]) -> Int32 {
        assertOffMainThread("SystemCommand.status")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        guard (try? process.run()) != nil else { return -1 }
        exited.wait()
        return process.terminationStatus
    }
}

enum MemoryPressureLevel: String, Sendable {
    case normal = "Normal"
    case warning = "Warning"
    case critical = "Critical"
    case unknown = "Unavailable"
}

struct BatterySnapshot: Sendable {
    var percentage: Int?
    var isCharging: Bool
    var powerSource: String
    var cycleCount: Int?
    var maximumCapacityPercent: Int?
    var condition: String
    var lowPowerMode: Bool
}

struct ProcessSample: Identifiable, Sendable {
    var pid: Int
    var cpuPercent: Double
    var memoryBytes: Int64
    var name: String
    var executablePath: String

    var id: Int { pid }
}

struct PerformanceSnapshot: Sendable {
    var memory: MemorySnapshot?
    var pressure: MemoryPressureLevel = .unknown
    var availablePercent: Int?
    var swapUsedBytes: Int64 = 0
    var swapTotalBytes: Int64 = 0
    var cpuPercent: Double = 0
    var thermalState: String = "Unavailable"
    var battery: BatterySnapshot?
    var topProcesses: [ProcessSample] = []
    var storage: VolumeSpace?

    /// Every metric here except the process list now comes from mach/sysctl calls, so a
    /// refresh with `includeProcesses: false` spawns nothing at all.
    ///
    /// The default-initialized `PerformanceSnapshot()` is the placeholder to show until a
    /// background refresh delivers real values. Still blocking when it does run the
    /// process list — never call this from the main thread.
    ///
    /// - Parameters:
    ///   - includeProcesses: Runs `ps -A` to build the top-process table. This walks every
    ///     process on the system, so callers polling on a timer should ask for it sparingly
    ///     and reuse `previousProcesses` in between.
    ///   - previousProcesses: Carried forward when the process list is skipped, so the
    ///     table keeps its last known contents instead of blanking.
    static func current(
        includeProcesses: Bool = true,
        previousProcesses: [ProcessSample] = []
    ) -> PerformanceSnapshot {
        let memory = MemorySnapshot.current()
        let pressure = memoryPressure(memory: memory)
        let swap = swapUsage()
        let processReport = includeProcesses ? processSamples() : nil
        return PerformanceSnapshot(
            memory: memory,
            pressure: pressure.level,
            availablePercent: pressure.percent,
            swapUsedBytes: swap.used,
            swapTotalBytes: swap.total,
            cpuPercent: processReport?.totalCPU ?? hostCPUPercent(),
            thermalState: thermalStateName(ProcessInfo.processInfo.thermalState),
            battery: batterySnapshot(),
            topProcesses: processReport?.processes ?? previousProcesses,
            storage: VolumeSpace.forRoot(URL(fileURLWithPath: "/"))
        )
    }

    /// Whole-machine CPU busy share from mach tick counters, used on the cheap refreshes
    /// where the `ps` process list is skipped.
    private static func hostCPUPercent() -> Double {
        var load = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let status = withUnsafeMutablePointer(to: &load) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return 0 }

        let ticks: [UInt64] = withUnsafeBytes(of: load.cpu_ticks) { raw in
            raw.bindMemory(to: UInt32.self).map(UInt64.init)
        }
        guard ticks.count >= 4 else { return 0 }
        let used = ticks[Int(CPU_STATE_USER)] + ticks[Int(CPU_STATE_SYSTEM)] + ticks[Int(CPU_STATE_NICE)]
        let total = used + ticks[Int(CPU_STATE_IDLE)]

        return cpuTickTracker.withLock { previous -> Double in
            defer { previous = (used, total) }
            guard let last = previous, total > last.total else { return 0 }
            return min(100, Double(used - last.used) / Double(total - last.total) * 100)
        }
    }

    private static let cpuTickTracker = Locked<(used: UInt64, total: UInt64)?>(nil)

    /// Reads the kernel's own pressure level via sysctl instead of shelling out to
    /// `/usr/bin/memory_pressure`. Same answer, no process spawn — this used to run
    /// every five seconds.
    private static func memoryPressure(memory: MemorySnapshot?) -> (level: MemoryPressureLevel, percent: Int?) {
        let percent: Int? = memory.flatMap { snapshot in
            guard snapshot.physical > 0 else { return nil }
            let availableBytes = snapshot.free + snapshot.inactive + snapshot.speculative
            return Int((Double(availableBytes) / Double(snapshot.physical) * 100).rounded())
        }

        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else {
            return (.unknown, percent)
        }

        // Kernel levels: 1 normal, 2 warning, 4 critical.
        switch level {
        case 1: return (.normal, percent)
        case 2: return (.warning, percent)
        case 4: return (.critical, percent)
        default: return (.unknown, percent)
        }
    }

    /// `vm.swapusage` read straight from sysctl rather than by parsing `/usr/sbin/sysctl`
    /// output.
    private static func swapUsage() -> (used: Int64, total: Int64) {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return (0, 0) }
        return (Int64(usage.xsu_used), Int64(usage.xsu_total))
    }

    private static func processSamples() -> (totalCPU: Double, processes: [ProcessSample]) {
        let samples = allProcessSamples()
        let total = samples.reduce(0) { $0 + $1.cpuPercent }
        let cores = max(1, ProcessInfo.processInfo.activeProcessorCount)
        return (
            min(100, total / Double(cores)),
            Array(samples.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(5))
        )
    }

    /// Full process table used by an explicit, short resource analysis. Normal
    /// Performance polling keeps using the five-row summary above.
    static func allProcessSamples() -> [ProcessSample] {
        let output = SystemCommand.run(
            "/bin/ps",
            arguments: ["-A", "-o", "pid=", "-o", "%cpu=", "-o", "rss=", "-o", "comm="]
        )
        guard output.status == 0 else { return [] }

        var samples: [ProcessSample] = []
        for line in output.stdout.split(separator: "\n") {
            let fields = line.split(maxSplits: 3, whereSeparator: \.isWhitespace)
            guard fields.count == 4,
                  let pid = Int(fields[0]),
                  let cpu = Double(fields[1]),
                  let rss = Int64(fields[2])
            else { continue }
            let executablePath = String(fields[3])
            samples.append(ProcessSample(
                pid: pid,
                cpuPercent: cpu,
                memoryBytes: rss * 1_024,
                name: URL(fileURLWithPath: executablePath).lastPathComponent,
                executablePath: executablePath
            ))
        }
        return samples
    }

    private static func thermalStateName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Unavailable"
        }
    }

    private static func batterySnapshot() -> BatterySnapshot? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef],
              let source = sources.first,
              let raw = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue()
                    as? [String: Any]
        else { return nil }

        let current = raw[kIOPSCurrentCapacityKey as String] as? Int
        let maximum = raw[kIOPSMaxCapacityKey as String] as? Int
        let percentage: Int?
        if let current, let maximum, maximum > 0 {
            percentage = Int((Double(current) / Double(maximum) * 100).rounded())
        } else {
            percentage = nil
        }

        let registry = batteryRegistryProperties()
        let cycleCount = registry["CycleCount"] as? Int
        let design = (registry["DesignCapacity"] as? Int) ?? 0
        let rawMaximum = (registry["AppleRawMaxCapacity"] as? Int)
            ?? (registry["MaxCapacity"] as? Int)
            ?? 0
        let health = design > 0 && rawMaximum > 0
            ? min(100, Int((Double(rawMaximum) / Double(design) * 100).rounded()))
            : nil
        let condition = (registry["BatteryHealth"] as? String)
            ?? ((registry["PermanentFailureStatus"] as? Int) == 0 ? "Normal" : "Service recommended")

        return BatterySnapshot(
            percentage: percentage,
            isCharging: raw[kIOPSIsChargingKey as String] as? Bool ?? false,
            powerSource: raw[kIOPSPowerSourceStateKey as String] as? String ?? "Unknown",
            cycleCount: cycleCount,
            maximumCapacityPercent: health,
            condition: condition,
            lowPowerMode: lowPowerModeEnabled()
        )
    }

    private static func batteryRegistryProperties() -> [String: Any] {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleSmartBattery")
        )
        guard service != 0 else { return [:] }
        defer { IOObjectRelease(service) }

        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(
            service,
            &properties,
            kCFAllocatorDefault,
            0
        ) == KERN_SUCCESS else { return [:] }
        return properties?.takeRetainedValue() as? [String: Any] ?? [:]
    }

    /// Foundation reports this directly. The old implementation parsed `pmset -g custom`,
    /// a third subprocess on every refresh.
    private static func lowPowerModeEnabled() -> Bool {
        ProcessInfo.processInfo.isLowPowerModeEnabled
    }
}

struct SustainedProcessSample: Identifiable, Sendable {
    var pid: Int
    var name: String
    var executablePath: String
    var applicationURL: URL?
    var averageCPUPercent: Double
    var peakCPUPercent: Double
    var averageMemoryBytes: Int64
    var appearances: Int

    var id: String { "\(pid):\(executablePath)" }

    var canQuit: Bool {
        guard pid > 1, pid != Int(getpid()), let applicationURL else { return false }
        let appPath = applicationURL.standardizedFileURL.path
        return !appPath.hasPrefix("/System/")
            && appPath != Bundle.main.bundleURL.standardizedFileURL.path
    }
}

enum SustainedProcessAnalyzer {
    static let defaultSampleCount = 5
    static let defaultInterval: Duration = .seconds(2)

    /// Samples only after a user asks for an analysis. Five readings over eight
    /// seconds avoid promoting a brief launch spike as a persistent resource user.
    static func analyze(
        sampleCount: Int = defaultSampleCount,
        interval: Duration = defaultInterval
    ) async -> [SustainedProcessSample] {
        let count = max(1, min(sampleCount, 30))
        var snapshots: [[ProcessSample]] = []
        for index in 0..<count {
            guard !Task.isCancelled else { break }
            snapshots.append(PerformanceSnapshot.allProcessSamples())
            if index < count - 1 {
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    break
                }
            }
        }
        return aggregate(snapshots)
    }

    static func aggregate(
        _ snapshots: [[ProcessSample]],
        limit: Int = 8
    ) -> [SustainedProcessSample] {
        struct Key: Hashable {
            var identity: String
        }
        struct Totals {
            var pid: Int
            var name: String
            var executablePath: String
            var applicationURL: URL?
            var cpu = 0.0
            var peakCPU = 0.0
            var memory: Int64 = 0
            var appearances = 0
        }

        var totals: [Key: Totals] = [:]
        for snapshot in snapshots {
            var combined: [Key: Totals] = [:]
            for sample in snapshot {
                let appURL = applicationURL(forExecutablePath: sample.executablePath)
                let key = Key(
                    identity: appURL?.path
                        ?? "\(sample.pid):\(sample.executablePath)"
                )
                let displayName = appURL
                    .flatMap { Bundle(url: $0) }
                    .flatMap {
                        ($0.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                            ?? ($0.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    }
                    ?? sample.name
                var current = combined[key] ?? Totals(
                    pid: sample.pid,
                    name: displayName,
                    executablePath: sample.executablePath,
                    applicationURL: appURL
                )
                current.pid = min(current.pid, sample.pid)
                current.cpu += sample.cpuPercent
                current.memory += sample.memoryBytes
                combined[key] = current
            }
            for (key, current) in combined {
                var total = totals[key] ?? Totals(
                    pid: current.pid,
                    name: current.name,
                    executablePath: current.executablePath,
                    applicationURL: current.applicationURL
                )
                total.pid = min(total.pid, current.pid)
                total.cpu += current.cpu
                total.peakCPU = max(total.peakCPU, current.cpu)
                total.memory += current.memory
                total.appearances += 1
                totals[key] = total
            }
        }

        let minimumAppearances = min(2, snapshots.count)
        return totals.compactMap { _, total -> SustainedProcessSample? in
            guard total.appearances >= minimumAppearances else { return nil }
            return SustainedProcessSample(
                pid: total.pid,
                name: total.name,
                executablePath: total.executablePath,
                applicationURL: total.applicationURL,
                averageCPUPercent: total.cpu / Double(total.appearances),
                peakCPUPercent: total.peakCPU,
                averageMemoryBytes: total.memory / Int64(total.appearances),
                appearances: total.appearances
            )
        }
        .sorted {
            impactScore($0) == impactScore($1)
                ? $0.averageCPUPercent > $1.averageCPUPercent
                : impactScore($0) > impactScore($1)
        }
        .prefix(max(0, limit))
        .map { $0 }
    }

    static func applicationURL(forExecutablePath path: String) -> URL? {
        let lower = path.lowercased()
        if lower.hasSuffix(".app") {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        guard let marker = lower.range(of: ".app/") else { return nil }
        let end = marker.lowerBound.utf16Offset(in: lower) + 4
        let prefix = NSString(string: path).substring(to: end)
        return URL(fileURLWithPath: prefix).standardizedFileURL
    }

    private static func impactScore(_ sample: SustainedProcessSample) -> Double {
        sample.averageCPUPercent
            + Double(sample.averageMemoryBytes) / Double(512 * 1_024 * 1_024)
    }
}
