import SwiftUI

struct SmartCareRecommendation: Identifiable, Sendable {
    enum Severity: Sendable {
        case notice
        case warning
    }

    var id: String
    var title: String
    var detail: String
    var systemImage: String
    var destination: Module
    var severity: Severity
}

@MainActor
final class SmartCareViewModel: ObservableObject {
    @Published private(set) var categories: [CategoryScanResult] = []
    @Published private(set) var duplicateGroups: [DuplicateGroup] = []
    @Published private(set) var leftovers: [AppLeftover] = []
    @Published private(set) var scanning = false
    @Published private(set) var cleaning = false
    @Published private(set) var status = ""
    @Published private(set) var result: MaintenanceResult?
    @Published private(set) var recommendations: [SmartCareRecommendation] = []
    @Published var selectedCategoryIDs: Set<String> = []
    @Published var includeDuplicates = true
    /// Leftovers stay opt-out-by-default-off: they are orphaned bundle-ID guesses, not
    /// safety-database entries, so Smart Care surfaces them but never pre-checks them.
    @Published var includeLeftovers = false

    var selectedJunk: [JunkItem] {
        categories
            .filter { selectedCategoryIDs.contains($0.id) }
            .flatMap(\.items)
    }
    var duplicateVictims: [FileEntry] {
        guard includeDuplicates else { return [] }
        return duplicateGroups.flatMap { Array($0.files.dropFirst()) }
    }
    var leftoverBytes: Int64 { leftovers.reduce(0) { $0 + $1.size } }
    var hasFindings: Bool {
        !categories.isEmpty || !duplicateGroups.isEmpty
            || !leftovers.isEmpty || !recommendations.isEmpty
    }
    var selectedBytes: Int64 {
        selectedJunk.reduce(0) { $0 + $1.size }
            + duplicateGroups.reduce(0) { $0 + (includeDuplicates ? $1.reclaimable : 0) }
            + (includeLeftovers ? leftoverBytes : 0)
    }

    func scan(fullDiskAccess: Bool) async {
        guard !scanning else { return }
        scanning = true
        result = nil
        status = "Checking cleanup, duplicates, and system health…"

        async let cleanupScan = JunkScanner.scanAll(fullDiskAccessGranted: fullDiskAccess)
        async let fileScan = FileWalker.collectParallel(
            root: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads"),
            minSize: 1_048_576,
            useLogicalSizeForMinimum: true
        )
        async let diagnosticScan = Task.detached(priority: .utility) {
            (PerformanceSnapshot.current(), StartupItemScanner.scan())
        }.value
        async let leftoverScan = ApplicationScanner.orphanedLeftovers(
            installedApplications: await ApplicationScanner.installedApplications()
        )

        let (results, entries, diagnostics) = await (cleanupScan, fileScan, diagnosticScan)
        categories = results.filter { $0.category.risk == .safe && !$0.items.isEmpty }
        selectedCategoryIDs = Set(categories.map(\.id))

        status = "Checking Downloads for exact duplicates…"
        duplicateGroups = await DuplicateFinder.find(in: entries)

        status = "Looking for leftovers from apps you no longer have…"
        leftovers = await leftoverScan

        recommendations = Self.makeRecommendations(
            performance: diagnostics.0,
            startupItems: diagnostics.1
        )
        status = ""
        scanning = false
    }

    static func makeRecommendations(
        performance: PerformanceSnapshot,
        startupItems: [StartupItem]
    ) -> [SmartCareRecommendation] {
        var output: [SmartCareRecommendation] = []

        if performance.pressure == .warning || performance.pressure == .critical {
            output.append(
                SmartCareRecommendation(
                    id: "memory-pressure",
                    title: "\(performance.pressure.rawValue) memory pressure",
                    detail: "Review the top memory users before purging file cache. Purging does not close apps or erase their memory.",
                    systemImage: "memorychip",
                    destination: .performance,
                    severity: .warning
                )
            )
        }
        if performance.thermalState != "Nominal" {
            output.append(
                SmartCareRecommendation(
                    id: "thermal-state",
                    title: "\(performance.thermalState) thermal state",
                    detail: "CPU performance may be reduced until the Mac cools down.",
                    systemImage: "thermometer.high",
                    destination: .performance,
                    severity: .warning
                )
            )
        }
        if let battery = performance.battery {
            if battery.condition != "Normal"
                || (battery.maximumCapacityPercent.map { $0 < 80 } ?? false) {
                let capacityDetail = battery.maximumCapacityPercent
                    .map { " with \($0)% maximum capacity." }
                    ?? "."
                output.append(
                    SmartCareRecommendation(
                        id: "battery-health",
                        title: "Review battery health",
                        detail: "Battery condition is \(battery.condition.lowercased())"
                            + capacityDetail,
                        systemImage: "battery.25percent",
                        destination: .performance,
                        severity: .warning
                    )
                )
            } else if let percentage = battery.percentage,
                      percentage <= 25,
                      !battery.lowPowerMode {
                output.append(
                    SmartCareRecommendation(
                        id: "low-power-mode",
                        title: "Low Power Mode is available",
                        detail: "The battery is at \(percentage)%. Performance can enable Low Power Mode for the battery profile.",
                        systemImage: "leaf",
                        destination: .performance,
                        severity: .notice
                    )
                )
            }
        }

        let brokenItems = startupItems.filter(\.isBroken).count
        if brokenItems > 0 {
            output.append(
                SmartCareRecommendation(
                    id: "broken-startup-items",
                    title: "\(brokenItems) broken startup item\(brokenItems == 1 ? "" : "s")",
                    detail: "The configured executable is missing. Review the plist before disabling it.",
                    systemImage: "exclamationmark.triangle",
                    destination: .startupItems,
                    severity: .notice
                )
            )
        }
        return output
    }

    func clean() async {
        cleaning = true
        result = nil
        let junk = selectedJunk
        let groups = includeDuplicates ? duplicateGroups : []
        // Leftovers live outside the safety database, so they are trashed as an explicit
        // separate batch rather than folded into the junk deleter.
        let leftoverItems = includeLeftovers ? leftovers : []
        let outcome = await Task.detached(priority: .userInitiated) {
            let cleanup = Deleter.run(junk, permanent: false)
            var duplicateURLs: [URL] = []
            var sizes: [URL: Int64] = [:]
            for group in groups {
                let verified = group.files.filter {
                    DuplicateFinder.stillMatches($0, digest: group.contentDigest)
                }
                guard verified.count > 1 else { continue }
                for victim in verified.dropFirst() {
                    duplicateURLs.append(victim.url)
                    sizes[victim.url] = victim.size
                }
            }
            let duplicateResult = FileActions.trash(duplicateURLs, sizes: sizes)
            let leftoverResult = FileActions.trash(
                leftoverItems.map(\.url),
                sizes: Dictionary(
                    leftoverItems.map { ($0.url, $0.size) },
                    uniquingKeysWith: { first, _ in first }
                )
            )
            return (
                cleanup.freedBytes + duplicateResult.freed + leftoverResult.freed,
                cleanup.failures.count + duplicateResult.failed.count
                    + leftoverResult.failed.count
            )
        }.value

        result = MaintenanceResult(
            succeeded: outcome.1 == 0,
            message: outcome.1 == 0
                ? "Moved \(outcome.0.formattedBytes) to Trash."
                : "Finished with \(outcome.1) item\(outcome.1 == 1 ? "" : "s") that could not be moved."
        )
        cleaning = false
        if outcome.1 == 0 {
            categories = []
            duplicateGroups = []
            leftovers = []
            selectedCategoryIDs = []
            includeLeftovers = false
        }
    }
}

struct SmartCareView: View {
    @EnvironmentObject private var permissions: PermissionsModel
    @EnvironmentObject private var navigation: AppNavigationModel
    @StateObject private var vm = SmartCareViewModel()
    @State private var confirming = false
    private let theme = Module.smartCare.theme

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(
                title: "Smart Care",
                subtitle: "Safe cleanup, exact duplicates, app leftovers, and system health in one pass."
            ) {
                if vm.hasFindings {
                    Button { Task { await vm.scan(fullDiskAccess: permissions.fullDiskAccessGranted) } } label: {
                        Label("Rescan", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(GradientButtonStyle(colors: theme.colors, prominent: false))
                }
            }
            content
                .animation(Motion.screen, value: vm.scanning)
                .animation(Motion.arrive, value: vm.hasFindings)
        }
        .confirmationDialog(
            "Clean \(vm.selectedBytes.formattedBytes)?",
            isPresented: $confirming,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) { Task { await vm.clean() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only the checked safe categories and verified duplicate copies will be moved. One copy from every duplicate group remains.")
        }
        .task(id: navigation.smartCareScanPending) {
            guard navigation.smartCareScanPending else { return }
            navigation.consumeSmartCareScanRequest()
            await vm.scan(fullDiskAccess: permissions.fullDiskAccessGranted)
        }
    }

    /// One checkbox row in the review list. Every finding — junk category, duplicates,
    /// leftovers — is the same shape so the list reads as one decision repeated.
    private func selectableCard(
        index: Int,
        isOn: Binding<Bool>,
        systemImage: String,
        colors: [Color],
        title: String,
        detail: String,
        size: Int64
    ) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: 12) {
                IconTile(systemImage: systemImage, colors: colors, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).fontWeight(.medium)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(size.formattedBytes)
                    .monospacedDigit()
                    .fontWeight(.medium)
            }
        }
        .toggleStyle(.checkbox)
        .padding(14)
        .cardStyle()
        .opacity(isOn.wrappedValue ? 1 : 0.62)
        .animation(Motion.snappy, value: isOn.wrappedValue)
        .staggeredAppear(index)
    }

    @ViewBuilder private var content: some View {
        if vm.scanning {
            ScanningIndicator(theme: theme, status: vm.status).frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
        } else if !vm.hasFindings {
            VStack(spacing: 18) {
                BigScanButton(title: "Scan", systemImage: "checkmark.shield", theme: theme) {
                    Task { await vm.scan(fullDiskAccess: permissions.fullDiskAccessGranted) }
                }
                Text("Safe caches, logs, developer junk, duplicate downloads, and leftovers from apps you removed")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                if let result = vm.result {
                    Label(result.message, systemImage: result.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(result.succeeded ? .green : .red)
                        .staggeredAppear(1)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity)
        } else {
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(Array(vm.categories.enumerated()), id: \.element.id) { index, category in
                        selectableCard(
                            index: index,
                            isOn: Binding(
                                get: { vm.selectedCategoryIDs.contains(category.id) },
                                set: { enabled in
                                    if enabled { vm.selectedCategoryIDs.insert(category.id) }
                                    else { vm.selectedCategoryIDs.remove(category.id) }
                                }
                            ),
                            systemImage: category.category.systemImage,
                            colors: CategoryTint.colors(for: category.id),
                            title: category.category.name,
                            detail: "\(category.items.count) items",
                            size: category.totalSize
                        )
                    }

                    if !vm.duplicateGroups.isEmpty {
                        selectableCard(
                            index: vm.categories.count,
                            isOn: $vm.includeDuplicates,
                            systemImage: "square.on.square",
                            colors: Module.duplicates.theme.colors,
                            title: "Exact duplicates in Downloads",
                            detail: "\(vm.duplicateGroups.count) verified groups",
                            size: vm.duplicateGroups.reduce(0) { $0 + $1.reclaimable }
                        )
                    }

                    if !vm.leftovers.isEmpty {
                        selectableCard(
                            index: vm.categories.count + 1,
                            isOn: $vm.includeLeftovers,
                            systemImage: "shippingbox",
                            colors: Module.uninstaller.theme.colors,
                            title: "Leftovers from removed apps",
                            detail: "\(vm.leftovers.count) orphaned items · review before cleaning",
                            size: vm.leftoverBytes
                        )
                    }

                    ForEach(Array(vm.recommendations.enumerated()), id: \.element.id) { index, recommendation in
                        HStack(spacing: 12) {
                            IconTile(
                                systemImage: recommendation.systemImage,
                                colors: recommendation.severity == .warning
                                    ? [.orange, .red]
                                    : Module.performance.theme.colors,
                                size: 34
                            )
                            VStack(alignment: .leading, spacing: 3) {
                                Text(recommendation.title).fontWeight(.medium)
                                Text(recommendation.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Review") {
                                withAnimation(Motion.screen) {
                                    navigation.selection = recommendation.destination
                                }
                            }
                            .buttonStyle(GradientButtonStyle(
                                colors: recommendation.destination.theme.colors,
                                prominent: false
                            ))
                        }
                        .padding(14)
                        .cardStyle()
                        .staggeredAppear(vm.categories.count + 2 + index)
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, Layout.gutter).frame(maxWidth: 780).frame(maxWidth: .infinity)
            }
            .transition(.opacity)
            .safeAreaInset(edge: .bottom) {
                if !vm.categories.isEmpty || !vm.duplicateGroups.isEmpty || !vm.leftovers.isEmpty {
                    HStack {
                        Text("\(vm.selectedBytes.formattedBytes) selected")
                            .fontWeight(.medium)
                            .monospacedDigit()
                            .contentTransition(.numericText())
                            .animation(Motion.readout, value: vm.selectedBytes)
                        Spacer()
                        if vm.cleaning {
                            ProgressView()
                        } else {
                            Button("Clean") { confirming = true }
                                .buttonStyle(GradientButtonStyle(colors: theme.colors))
                                .disabled(vm.selectedBytes == 0)
                        }
                    }
                    .padding(.horizontal, 24).padding(.vertical, 12)
                    .background(.regularMaterial)
                }
            }
        }
    }
}
