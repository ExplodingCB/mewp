import Foundation
import SwiftUI

@MainActor
final class CleanupViewModel: ObservableObject {

    enum Phase: Equatable {
        case idle
        case scanning
        case results
        case cleaning
        case done(DeletionOutcomeSummary)
    }

    /// Lightweight, Equatable snapshot of an outcome for the `.done` phase.
    struct DeletionOutcomeSummary: Equatable {
        var freedBytes: Int64
        var deletedCount: Int
        var failureCount: Int
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var results: [CategoryScanResult] = []
    @Published var selectedItemIDs: Set<UUID> = []
    @Published var expandedCategoryIDs: Set<String> = []
    @Published var permanentDelete: Bool = false

    @Published private(set) var scanStatus: String = ""
    @Published private(set) var cleanProgress: Double = 0

    // MARK: - Derived values

    var totalFoundBytes: Int64 { results.reduce(0) { $0 + $1.totalSize } }

    var allItems: [JunkItem] { results.flatMap(\.items) }

    var selectedItems: [JunkItem] { allItems.filter { selectedItemIDs.contains($0.id) } }

    var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.size } }

    var selectedCount: Int { selectedItems.count }

    var selectedIncludesPermanentItems: Bool {
        selectedItems.contains { $0.strategy.isAlwaysPermanent }
    }

    var selectedIncludesAdministratorItems: Bool {
        selectedItems.contains { $0.requiresAdministrator }
    }

    var willPermanentlyDeleteAnything: Bool {
        permanentDelete || selectedIncludesPermanentItems
    }

    var hasResults: Bool {
        switch phase {
        case .results, .cleaning, .done: return true
        default: return false
        }
    }

    var needsFullDiskAccessForSome: Bool { results.contains { $0.lockedByPermission } }

    // MARK: - Scanning

    func scan(fullDiskAccessGranted: Bool) async {
        phase = .scanning
        scanStatus = "Scanning your Mac for junk…"
        selectedItemIDs = []

        let scanned = await JunkScanner.scanAll(fullDiskAccessGranted: fullDiskAccessGranted)

        results = scanned
        // Pre-select every item in "safe" categories; leave caution/risky opt-in.
        var preselect = Set<UUID>()
        for result in scanned where result.category.selectedByDefault {
            for item in result.items { preselect.insert(item.id) }
        }
        selectedItemIDs = preselect
        // Auto-expand categories that actually found something.
        expandedCategoryIDs = Set(scanned.filter { !$0.isEmpty }.map(\.id))
        phase = .results
    }

    // MARK: - Selection helpers

    func isSelected(_ item: JunkItem) -> Bool { selectedItemIDs.contains(item.id) }

    func toggle(_ item: JunkItem) {
        if selectedItemIDs.contains(item.id) { selectedItemIDs.remove(item.id) }
        else { selectedItemIDs.insert(item.id) }
    }

    func categorySelectionState(_ result: CategoryScanResult) -> ToggleState {
        let ids = Set(result.items.map(\.id))
        let selected = ids.intersection(selectedItemIDs)
        if selected.isEmpty { return .off }
        if selected.count == ids.count { return .on }
        return .mixed
    }

    func setCategory(_ result: CategoryScanResult, selected: Bool) {
        let ids = result.items.map(\.id)
        if selected { selectedItemIDs.formUnion(ids) }
        else { selectedItemIDs.subtract(ids) }
    }

    // MARK: - Cleaning

    func clean() async {
        let items = selectedItems
        guard !items.isEmpty else { return }
        phase = .cleaning
        cleanProgress = 0

        let regularItems = items.filter { !$0.requiresAdministrator }
        let administratorItems = items.filter(\.requiresAdministrator)
        let permanent = permanentDelete
        var outcome: DeletionOutcome = await Task.detached(priority: .userInitiated) {
            Deleter.run(regularItems, permanent: permanent) { fraction in
                Task { @MainActor in self.cleanProgress = fraction }
            }
        }.value
        if !administratorItems.isEmpty {
            let result = await Task.detached(priority: .userInitiated) {
                MaintenanceRunner.trashAdministratorItems(administratorItems.map(\.url))
            }.value
            if result.succeeded {
                outcome.freedBytes += administratorItems.reduce(0) { $0 + $1.size }
                outcome.deletedCount += administratorItems.count
            } else {
                outcome.failures.append(result.message)
                outcome.failedItemURLs.formUnion(administratorItems.map(\.url))
            }
        }

        // Keep failed items visible so the result does not claim they vanished.
        let cleanedIDs = Set(items.filter {
            !outcome.failedItemURLs.contains($0.url)
        }.map(\.id))
        results = results.map { r in
            var r = r
            r.items.removeAll { cleanedIDs.contains($0.id) }
            return r
        }
        selectedItemIDs.subtract(cleanedIDs)

        phase = .done(DeletionOutcomeSummary(
            freedBytes: outcome.freedBytes,
            deletedCount: outcome.deletedCount,
            failureCount: outcome.failures.count
        ))
    }

    func reset() {
        phase = .idle
        results = []
        selectedItemIDs = []
        expandedCategoryIDs = []
        scanStatus = ""
        cleanProgress = 0
    }
}

enum ToggleState { case on, off, mixed }
