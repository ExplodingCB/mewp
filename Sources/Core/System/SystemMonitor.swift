import Foundation
import Darwin
import IOKit.ps

struct SystemMonitorSnapshot: Sendable {
    var cpuPercent: Double = 0
    var memoryUsed: Int64 = 0
    var memoryTotal: Int64 = 0
    var diskFree: Int64 = 0
    var diskTotal: Int64 = 0
    var downloadBytesPerSecond: Int64 = 0
    var uploadBytesPerSecond: Int64 = 0
    var batteryPercent: Int?
    var charging = false
    var trashBytes: Int64 = 0
}

actor SystemMonitorSampler {
    private var previousCPUTicks: (used: UInt64, total: UInt64)?
    private var previousNetwork: (received: UInt64, sent: UInt64, time: Date)?
    private var lastTrashBytes: Int64 = 0
    private var lastTrashCheck = Date.distantPast

    func sample() -> SystemMonitorSnapshot {
        let memory = MemorySnapshot.current()
        let cpu = cpuUsage()
        let network = networkRates()
        let battery = batteryState()
        let disk = VolumeSpace.forRoot(URL(fileURLWithPath: "/"))
        let now = Date()
        // Measuring the Trash means walking it recursively. Every 60 seconds was far too
        // often for a number that changes when the user deletes something; ten minutes
        // keeps the menu useful without the constant directory traversal.
        if now.timeIntervalSince(lastTrashCheck) >= 600 {
            let trash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
            lastTrashBytes = DirectoryScanner.measure(trash).allocatedBytes
            lastTrashCheck = now
        }

        let available = Int64((memory?.free ?? 0) + (memory?.inactive ?? 0) + (memory?.speculative ?? 0))
        let total = Int64(memory?.physical ?? 0)
        return SystemMonitorSnapshot(
            cpuPercent: cpu,
            memoryUsed: max(0, total - available),
            memoryTotal: total,
            diskFree: disk?.important ?? 0,
            diskTotal: disk?.total ?? 0,
            downloadBytesPerSecond: network.received,
            uploadBytesPerSecond: network.sent,
            batteryPercent: battery.percent,
            charging: battery.charging,
            trashBytes: lastTrashBytes
        )
    }

    private func cpuUsage() -> Double {
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
        defer { previousCPUTicks = (used, total) }
        guard let previous = previousCPUTicks, total > previous.total else { return 0 }
        return min(100, Double(used - previous.used) / Double(total - previous.total) * 100)
    }

    private func networkRates() -> (received: Int64, sent: Int64) {
        var addressList: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addressList) == 0, let first = addressList else { return (0, 0) }
        defer { freeifaddrs(addressList) }

        var received: UInt64 = 0
        var sent: UInt64 = 0
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            let item = current.pointee
            let flags = Int32(item.ifa_flags)
            if flags & IFF_LOOPBACK == 0,
               flags & IFF_UP != 0,
               let data = item.ifa_data?.assumingMemoryBound(to: if_data.self) {
                received += UInt64(data.pointee.ifi_ibytes)
                sent += UInt64(data.pointee.ifi_obytes)
            }
            pointer = item.ifa_next
        }

        let now = Date()
        defer { previousNetwork = (received, sent, now) }
        guard let previous = previousNetwork,
              received >= previous.received,
              sent >= previous.sent
        else { return (0, 0) }
        let interval = max(0.1, now.timeIntervalSince(previous.time))
        return (
            Int64(Double(received - previous.received) / interval),
            Int64(Double(sent - previous.sent) / interval)
        )
    }

    private func batteryState() -> (percent: Int?, charging: Bool) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef],
              let source = sources.first,
              let raw = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue()
                    as? [String: Any]
        else { return (nil, false) }
        let current = raw[kIOPSCurrentCapacityKey as String] as? Int
        let maximum = raw[kIOPSMaxCapacityKey as String] as? Int
        let percent = current.flatMap { current in
            maximum.flatMap { maximum in
                maximum > 0 ? Int((Double(current) / Double(maximum) * 100).rounded()) : nil
            }
        }
        return (percent, raw[kIOPSIsChargingKey as String] as? Bool ?? false)
    }
}

@MainActor
final class SystemMonitorModel: ObservableObject {
    @Published private(set) var snapshot = SystemMonitorSnapshot()
    private let sampler = SystemMonitorSampler()
    private var task: Task<Void, Never>?
    /// True while the menu-bar popover is open and someone is actually reading the
    /// numbers.
    private var watched = false

    /// Three seconds while the popover is open, so the meters feel live under the
    /// cursor. With it closed nobody can see the result, so it drops to once every five
    /// minutes — this loop previously sampled every two seconds for the entire life of
    /// the app, which is where a lot of the idle CPU went.
    private var interval: Duration { watched ? .seconds(3) : .seconds(300) }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.snapshot = await self.sampler.sample()
                try? await Task.sleep(for: self.interval)
            }
        }
    }

    /// Called by the menu-bar view as its popover appears and disappears. Opening it
    /// takes an immediate sample so the meters are current rather than up to five
    /// minutes stale.
    func setWatched(_ watched: Bool) {
        guard watched != self.watched else { return }
        self.watched = watched
        guard watched else { return }
        Task { [weak self] in
            guard let self else { return }
            self.snapshot = await self.sampler.sample()
        }
    }
}
