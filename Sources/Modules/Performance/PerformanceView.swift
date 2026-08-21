import SwiftUI
import AppKit

@MainActor
final class PerformanceViewModel: ObservableObject {
    // Placeholder only. Measuring here would block the main thread inside SwiftUI's
    // StateObject update, and the subprocess wait would re-enter the view graph.
    @Published private(set) var snapshot = PerformanceSnapshot()
    @Published private(set) var loaded = false
    @Published private(set) var refreshing = false
    @Published private(set) var running: MaintenanceOperation?
    @Published private(set) var changingPowerMode = false
    @Published private(set) var result: MaintenanceResult?
    @Published private(set) var resultOperation: MaintenanceOperation?
    @Published private(set) var powerModeResult: MaintenanceResult?
    @Published private(set) var analyzingProcesses = false
    @Published private(set) var processAnalysisLoaded = false
    @Published private(set) var sustainedProcesses: [SustainedProcessSample] = []
    @Published private(set) var processActionResult: MaintenanceResult?

    /// Ticks since the last time the process table was rebuilt. `ps -A` walks every
    /// process on the machine, so it runs every third poll — roughly every three
    /// minutes — instead of on every one.
    private var tick = 0
    private static let processEveryNTicks = 3

    func refresh(force: Bool = false) async {
        guard !refreshing else { return }
        refreshing = true
        let wantsProcesses = force || !loaded || tick % Self.processEveryNTicks == 0
        let carried = snapshot.topProcesses
        snapshot = await Task.detached(priority: .utility) {
            PerformanceSnapshot.current(
                includeProcesses: wantsProcesses,
                previousProcesses: carried
            )
        }.value
        tick &+= 1
        loaded = true
        refreshing = false
    }

    func run(_ operation: MaintenanceOperation) async {
        running = operation
        result = nil
        resultOperation = operation
        let outcome = await Task.detached(priority: .userInitiated) {
            MaintenanceRunner.run(operation)
        }.value
        result = outcome
        running = nil
        await refresh()
    }

    func setLowPowerMode(_ enabled: Bool) async {
        changingPowerMode = true
        powerModeResult = nil
        powerModeResult = await Task.detached(priority: .userInitiated) {
            MaintenanceRunner.setLowPowerMode(enabled: enabled)
        }.value
        changingPowerMode = false
        await refresh()
    }

    func analyzeProcesses() async {
        guard !analyzingProcesses else { return }
        analyzingProcesses = true
        processActionResult = nil
        sustainedProcesses = await Task.detached(priority: .userInitiated) {
            await SustainedProcessAnalyzer.analyze()
        }.value
        processAnalysisLoaded = true
        analyzingProcesses = false
    }

    func quit(_ process: SustainedProcessSample) {
        let application = process.applicationURL.flatMap { target in
            NSWorkspace.shared.runningApplications.first {
                $0.bundleURL?.standardizedFileURL == target.standardizedFileURL
            }
        } ?? NSRunningApplication(processIdentifier: pid_t(process.pid))
        guard process.canQuit, let application
        else {
            processActionResult = MaintenanceResult(
                succeeded: false,
                message: "The app is no longer running or cannot be quit here."
            )
            return
        }
        let succeeded = application.terminate()
        processActionResult = MaintenanceResult(
            succeeded: succeeded,
            message: succeeded
                ? "Asked \(process.name) to quit."
                : "\(process.name) did not accept the quit request."
        )
    }
}

struct PerformanceView: View {
    @EnvironmentObject private var navigation: AppNavigationModel
    @StateObject private var vm = PerformanceViewModel()
    @State private var pendingOperation: MaintenanceOperation?
    @State private var pendingLowPowerMode: Bool?
    @State private var pendingQuit: SustainedProcessSample?

    private let theme = Module.performance.theme

    var body: some View {
        VStack(spacing: 0) {
            header
            if !vm.loaded {
                VStack(spacing: 14) {
                    ProgressView().controlSize(.large)
                    Text("Reading system diagnostics…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        overviewCard
                        batteryCard
                        storageCard
                        processAnalysisCard
                        processesCard
                        maintenanceCard
                    }
                    .padding(20)
                    .frame(maxWidth: 900)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        // Polls only while this module is on screen; SwiftUI cancels the task on
        // disappear. A minute is plenty for a diagnostics page — Refresh is there when
        // you want numbers right now — and the expensive process list rebuilds on every
        // third tick.
        .task {
            while !Task.isCancelled {
                await vm.refresh()
                try? await Task.sleep(for: .seconds(60))
            }
        }
        .confirmationDialog(
            pendingOperation?.name ?? "Run maintenance task?",
            isPresented: Binding(
                get: { pendingOperation != nil },
                set: { if !$0 { pendingOperation = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let operation = pendingOperation {
                Button("Run", role: operation == .thinSnapshots ? .destructive : nil) {
                    pendingOperation = nil
                    Task { await vm.run(operation) }
                }
            }
            Button("Cancel", role: .cancel) { pendingOperation = nil }
        } message: {
            if let operation = pendingOperation {
                Text(operation.detail + " macOS will ask for an administrator password.")
            }
        }
        .confirmationDialog(
            pendingLowPowerMode == true ? "Enable Low Power Mode?" : "Disable Low Power Mode?",
            isPresented: Binding(
                get: { pendingLowPowerMode != nil },
                set: { if !$0 { pendingLowPowerMode = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let enabled = pendingLowPowerMode {
                Button(enabled ? "Enable" : "Disable") {
                    pendingLowPowerMode = nil
                    Task { await vm.setLowPowerMode(enabled) }
                }
            }
            Button("Cancel", role: .cancel) { pendingLowPowerMode = nil }
        } message: {
            Text("This changes the battery power profile with pmset. macOS will ask for an administrator password.")
        }
        .confirmationDialog(
            pendingQuit.map { "Quit \($0.name)?" } ?? "Quit this app?",
            isPresented: Binding(
                get: { pendingQuit != nil },
                set: { if !$0 { pendingQuit = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let process = pendingQuit {
                Button("Quit") {
                    pendingQuit = nil
                    vm.quit(process)
                }
            }
            Button("Cancel", role: .cancel) { pendingQuit = nil }
        } message: {
            if let process = pendingQuit {
                Text("This sends a normal quit request to \(process.name). Unsaved work may prompt inside the app.")
            }
        }
    }

    private var header: some View {
        ModuleHeader(
            title: "Performance",
            subtitle: "Check memory pressure, battery health, CPU load, and targeted maintenance."
        ) {
            HStack {
                Button {
                    NSWorkspace.shared.open(
                        URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
                    )
                } label: {
                    Label("Activity Monitor", systemImage: "waveform.path.ecg")
                }
                Button { Task { await vm.refresh(force: true) } } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(vm.refreshing)
            }
            .buttonStyle(GradientButtonStyle(colors: theme.colors, prominent: false))
        }
    }

    private var overviewCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("System load", systemImage: "memorychip").font(.headline)
                Spacer()
                Text("\(Int(vm.snapshot.cpuPercent.rounded()))% CPU")
                    .font(.callout).monospacedDigit().foregroundStyle(.secondary)
            }

            if let memory = vm.snapshot.memory {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                    metric("Pressure", pressureText, pressureColor)
                    metric("Available", availableText, .green)
                    metric("Swap used", vm.snapshot.swapUsedBytes.formattedBytes, .purple)
                    metric("Active", Int64(memory.active).formattedBytes, .blue)
                    metric("File cache", Int64(memory.inactive + memory.speculative).formattedBytes, .teal)
                    metric("Compressed", Int64(memory.compressed).formattedBytes, .orange)
                }
                Text("macOS uses spare RAM as a file cache. Purging that cache is useful for cold-cache testing, but it does not close apps or erase their memory.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Memory statistics are unavailable.").foregroundStyle(.secondary)
            }

            Divider()
            HStack {
                Label("Thermal state", systemImage: "thermometer.medium")
                Spacer()
                Text(vm.snapshot.thermalState)
                    .foregroundStyle(vm.snapshot.thermalState == "Nominal" ? .green : .orange)
            }
            .font(.callout)
        }
        .padding(16)
        .cardStyle()
    }

    private var pressureText: String {
        if let percent = vm.snapshot.availablePercent {
            return "\(vm.snapshot.pressure.rawValue) · \(percent)%"
        }
        return vm.snapshot.pressure.rawValue
    }

    private var availableText: String {
        guard let memory = vm.snapshot.memory else { return "Unavailable" }
        return Int64(memory.free + memory.inactive + memory.speculative).formattedBytes
    }

    private var pressureColor: Color {
        switch vm.snapshot.pressure {
        case .normal: return .green
        case .warning: return .orange
        case .critical: return .red
        case .unknown: return .secondary
        }
    }

    private func metric(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
            Text(value).fontWeight(.semibold).monospacedDigit().lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 9))
    }

    private var batteryCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Battery", systemImage: "battery.75percent").font(.headline)
                Spacer()
                Button("Battery settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.link)
            }

            if let battery = vm.snapshot.battery {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                    metric("Charge", battery.percentage.map { "\($0)%" } ?? "Unavailable", .green)
                    metric("Condition", battery.condition, battery.condition == "Normal" ? .green : .orange)
                    metric("Maximum capacity", battery.maximumCapacityPercent.map { "\($0)%" } ?? "Unavailable", .blue)
                    metric("Cycle count", battery.cycleCount.map(String.init) ?? "Unavailable", .purple)
                }

                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(battery.lowPowerMode ? "Low Power Mode is on" : "Low Power Mode is off")
                            .fontWeight(.medium)
                        Text("The switch changes the battery power profile. It does not affect the AC power profile.")
                            .font(.caption).foregroundStyle(.secondary)
                        if let result = vm.powerModeResult {
                            Label(result.message, systemImage: result.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(result.succeeded ? .green : .red)
                        }
                    }
                    Spacer()
                    if vm.changingPowerMode {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(battery.lowPowerMode ? "Turn off" : "Turn on") {
                            pendingLowPowerMode = !battery.lowPowerMode
                        }
                        .buttonStyle(GradientButtonStyle(colors: theme.colors, prominent: false))
                    }
                }
            } else {
                Text("No internal battery was found.").foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .cardStyle()
    }

    private var processesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Top CPU processes", systemImage: "list.number").font(.headline)
            if vm.snapshot.topProcesses.isEmpty {
                Text("Process statistics are unavailable.").foregroundStyle(.secondary)
            } else {
                ForEach(vm.snapshot.topProcesses) { process in
                    HStack {
                        Text(process.name).lineLimit(1)
                        Spacer()
                        Text("\(process.cpuPercent, specifier: "%.1f")%")
                            .monospacedDigit().frame(width: 60, alignment: .trailing)
                        Text(process.memoryBytes.formattedBytes)
                            .monospacedDigit().foregroundStyle(.secondary)
                            .frame(width: 85, alignment: .trailing)
                    }
                    .font(.callout)
                }
            }
        }
        .padding(16)
        .cardStyle()
    }

    private var storageCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Storage headroom", systemImage: "internaldrive").font(.headline)
                Spacer()
                Button("Cleanup") { navigation.selection = .cleanup }
                    .buttonStyle(.link)
                Button("Large files") { navigation.selection = .largeOld }
                    .buttonStyle(.link)
            }

            if let storage = vm.snapshot.storage, storage.total > 0 {
                let used = max(0, storage.total - storage.available)
                ProgressView(
                    value: Double(used),
                    total: Double(storage.total)
                )
                HStack {
                    Text("\(storage.available.formattedBytes) available now")
                    Spacer()
                    Text("\(used.formattedBytes) used of \(storage.total.formattedBytes)")
                }
                .font(.callout).monospacedDigit()

                if storage.important > storage.available {
                    Text("macOS reports \(storage.important.formattedBytes) available for important usage after reclaiming purgeable data.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Storage capacity is unavailable.").foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .cardStyle()
    }

    private var processAnalysisCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Sustained resource analysis", systemImage: "speedometer").font(.headline)
                    Text("Five CPU and memory readings over eight seconds")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if vm.analyzingProcesses {
                    ProgressView().controlSize(.small)
                } else {
                    Button(vm.processAnalysisLoaded ? "Analyze again" : "Analyze") {
                        Task { await vm.analyzeProcesses() }
                    }
                    .buttonStyle(GradientButtonStyle(colors: theme.colors, prominent: false))
                }
            }

            if vm.analyzingProcesses {
                ProgressView()
                Text("Watching for activity that persists across multiple readings…")
                    .font(.callout).foregroundStyle(.secondary)
            } else if !vm.processAnalysisLoaded {
                Text("Use this before disabling startup items or uninstalling apps. Short launch spikes are excluded from the result.")
                    .font(.callout).foregroundStyle(.secondary)
            } else if vm.sustainedProcesses.isEmpty {
                Text("No process stayed present for enough readings to compare.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(vm.sustainedProcesses) { process in
                    Divider()
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(process.name).fontWeight(.medium).lineLimit(1)
                            Text("Peak \(process.peakCPUPercent, specifier: "%.1f")% CPU")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(process.averageCPUPercent, specifier: "%.1f")% avg")
                            .font(.callout).monospacedDigit()
                            .frame(width: 72, alignment: .trailing)
                        Text(process.averageMemoryBytes.formattedBytes)
                            .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                            .frame(width: 82, alignment: .trailing)
                        if let applicationURL = process.applicationURL {
                            Button {
                                FileActions.revealInFinder(applicationURL)
                            } label: {
                                Image(systemName: "folder")
                            }
                            .buttonStyle(.borderless)
                            .help("Reveal app in Finder")
                        }
                        if process.canQuit {
                            Button("Quit") { pendingQuit = process }
                                .buttonStyle(.borderless)
                        }
                    }
                }
            }

            if let result = vm.processActionResult {
                Label(
                    result.message,
                    systemImage: result.succeeded
                        ? "checkmark.circle.fill"
                        : "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(result.succeeded ? .green : .red)
            }

            HStack {
                Spacer()
                Button("Review startup items") { navigation.selection = .startupItems }
                    .buttonStyle(.link)
            }
        }
        .padding(16)
        .cardStyle()
    }

    private var maintenanceCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Label("Maintenance and repair", systemImage: "wrench.and.screwdriver")
                    .font(.headline)
                Text("Problem-specific tools, not general speed boosts")
                    .font(.caption).foregroundStyle(.secondary)
            }
                .padding(16)
            Divider()
            ForEach(MaintenanceOperation.allCases) { operation in
                operationRow(operation)
                if operation.id != MaintenanceOperation.allCases.last?.id {
                    Divider().padding(.leading, 52)
                }
            }
        }
        .cardStyle()
    }

    private func operationRow(_ operation: MaintenanceOperation) -> some View {
        HStack(spacing: 12) {
            IconTile(systemImage: operation.systemImage, colors: theme.colors, size: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(operation.name).fontWeight(.medium)
                Text(operation.detail).font(.caption).foregroundStyle(.secondary)
                if vm.resultOperation == operation, let result = vm.result {
                    Label(result.message, systemImage: result.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(result.succeeded ? .green : .red)
                        .lineLimit(2)
                }
            }
            Spacer()
            if vm.running == operation {
                ProgressView().controlSize(.small)
            } else {
                Button("Run") { pendingOperation = operation }
                    .buttonStyle(GradientButtonStyle(colors: theme.colors, prominent: false))
                    .disabled(vm.running != nil)
            }
        }
        .padding(14)
    }
}
