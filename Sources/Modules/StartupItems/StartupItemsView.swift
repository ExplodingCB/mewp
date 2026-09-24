import SwiftUI
import ServiceManagement

@MainActor
final class StartupItemsViewModel: ObservableObject {
    @Published private(set) var items: [StartupItem] = []
    @Published private(set) var scanning = false
    @Published var query = ""
    @Published var brokenOnly = false
    @Published var reviewCandidatesOnly = false
    @Published var selection: Set<URL> = []
    @Published private(set) var changing = false
    @Published private(set) var actionResult: MaintenanceResult?

    var filtered: [StartupItem] {
        items.filter { item in
            (!brokenOnly || item.isBroken)
                && (!reviewCandidatesOnly || item.isReviewCandidate)
                && (query.isEmpty
                    || item.label.localizedCaseInsensitiveContains(query)
                    || item.ownerName?.localizedCaseInsensitiveContains(query) == true
                    || item.program?.localizedCaseInsensitiveContains(query) == true)
        }
    }

    var brokenCount: Int { items.filter(\.isBroken).count }
    var loadedCount: Int { items.filter(\.isLoaded).count }
    var disabledCount: Int { items.filter { !$0.isEnabled }.count }
    var reviewCandidateCount: Int { items.filter(\.isReviewCandidate).count }
    var selectedItem: StartupItem? {
        guard let url = selection.first else { return nil }
        return items.first { $0.id == url }
    }

    func scan() async {
        scanning = true
        selection = []
        items = await Task.detached(priority: .userInitiated) {
            StartupItemScanner.scan()
        }.value
        scanning = false
    }

    func revealSelected() {
        guard let url = selection.first else { return }
        FileActions.revealInFinder(url)
    }

    func setSelectedEnabled(_ enabled: Bool) async {
        guard let item = selectedItem else { return }
        changing = true
        actionResult = nil
        actionResult = await Task.detached(priority: .userInitiated) {
            StartupItemController.setEnabled(enabled, item: item)
        }.value
        await scan()
        selection = [item.plistURL]
        changing = false
    }
}

struct StartupItemsView: View {
    @StateObject private var vm = StartupItemsViewModel()
    @State private var pendingItem: StartupItem?

    private let theme = Module.startupItems.theme

    var body: some View {
        VStack(spacing: 0) {
            header
            controls
            content
            if !vm.items.isEmpty {
                footer
            }
        }
        .task {
            if vm.items.isEmpty { await vm.scan() }
        }
        .confirmationDialog(
            pendingItem.map { ($0.isEnabled ? "Disable " : "Enable ") + $0.label + "?" } ?? "Change startup item?",
            isPresented: Binding(
                get: { pendingItem != nil },
                set: { if !$0 { pendingItem = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let item = pendingItem {
                Button(item.isEnabled ? "Disable" : "Enable", role: item.isEnabled ? .destructive : nil) {
                    let enabled = !item.isEnabled
                    pendingItem = nil
                    Task { await vm.setSelectedEnabled(enabled) }
                }
            }
            Button("Cancel", role: .cancel) { pendingItem = nil }
        } message: {
            if let item = pendingItem {
                Text(item.isEnabled
                    ? "The service will be unloaded and prevented from starting. You can enable it again here."
                    : "The service will be allowed to start and Mewp will ask launchd to load it.")
            }
        }
    }

    private var header: some View {
        ModuleHeader(title: "Startup Items",
                     subtitle: "Inspect launch agents and daemons, including entries whose executable is missing.") {
            Button { Task { await vm.scan() } } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .buttonStyle(GradientButtonStyle(colors: theme.colors, prominent: false))
            .disabled(vm.scanning)
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            TextField("Filter by label or program", text: $vm.query)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 340)
            Toggle("Broken only", isOn: $vm.brokenOnly)
                .toggleStyle(.checkbox)
            Toggle("Review candidates", isOn: $vm.reviewCandidatesOnly)
                .toggleStyle(.checkbox)
            Spacer()
            Button("Login Items Settings") {
                SMAppService.openSystemSettingsLoginItems()
            }
            if !vm.selection.isEmpty {
                Button("Reveal plist") { vm.revealSelected() }
                if let item = vm.selectedItem, !item.isAppleItem {
                    Button(item.isEnabled ? "Disable" : "Enable") {
                        pendingItem = item
                    }
                    .buttonStyle(GradientButtonStyle(colors: theme.colors, prominent: false))
                    .disabled(vm.changing)
                }
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 10)
    }

    @ViewBuilder private var content: some View {
        if vm.scanning {
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text("Reading launch items…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if vm.filtered.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: vm.items.isEmpty ? "power" : "line.3.horizontal.decrease.circle")
                    .font(.system(size: 42, weight: .light)).foregroundStyle(.secondary)
                Text(vm.items.isEmpty ? "No launch items found" : "No matching launch items")
                    .font(.title3).fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Table(vm.filtered, selection: $vm.selection) {
                TableColumn("Label") { item in
                    HStack(spacing: 7) {
                        Image(systemName: item.isBroken ? "exclamationmark.triangle.fill" : "gearshape")
                            .foregroundStyle(item.isBroken ? .orange : .secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.label).lineLimit(1)
                            if let owner = item.ownerName {
                                Text(owner).font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
                TableColumn("Scope") { item in
                    Text(item.scope.rawValue).foregroundStyle(.secondary)
                }
                .width(110)
                TableColumn("Startup") { item in
                    Text(item.startupBehavior)
                        .foregroundStyle(item.isReviewCandidate ? .orange : .secondary)
                }
                .width(80)
                TableColumn("State") { item in
                    Text(item.isEnabled ? (item.isBroken ? "Broken" : (item.isLoaded ? "Loaded" : "Not loaded")) : "Disabled")
                        .foregroundStyle(item.isEnabled ? (item.isBroken ? .orange : (item.isLoaded ? .green : .secondary)) : .red)
                }
                .width(90)
                TableColumn("Program") { item in
                    Text(item.program ?? "No program declared")
                        .foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                }
            }
            .contextMenu(forSelectionType: URL.self) { _ in
                Button("Reveal plist in Finder") { vm.revealSelected() }
            }
            .tableCard()
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private var footer: some View {
        HStack {
            Text("\(vm.items.count) items · \(vm.loadedCount) loaded")
                .foregroundStyle(.secondary)
            if vm.disabledCount > 0 {
                Text("· \(vm.disabledCount) disabled")
                    .foregroundStyle(.red)
            }
            if vm.brokenCount > 0 {
                Text("· \(vm.brokenCount) broken")
                    .foregroundStyle(.orange)
            }
            if vm.reviewCandidateCount > 0 {
                Text("· \(vm.reviewCandidateCount) review candidates")
                    .foregroundStyle(.orange)
            }
            Spacer()
            if vm.changing {
                ProgressView().controlSize(.small)
            } else if let result = vm.actionResult {
                Label(result.message, systemImage: result.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(result.succeeded ? .green : .red)
            } else {
                Text("Apple items are protected")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 12)
    }
}
