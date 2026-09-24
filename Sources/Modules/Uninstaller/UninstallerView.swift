import SwiftUI
import AppKit

@MainActor
final class UninstallerViewModel: ObservableObject {
    @Published private(set) var applications: [InstalledApplication] = []
    @Published private(set) var leftovers: [AppLeftover] = []
    @Published private(set) var scanningApps = false
    @Published private(set) var scanningLeftovers = false
    @Published private(set) var uninstalling = false
    @Published private(set) var result: MaintenanceResult?
    @Published private(set) var orphanedLeftovers: [AppLeftover] = []
    @Published private(set) var scanningOrphans = false
    @Published private(set) var trashingOrphans = false
    @Published var selectedAppURL: URL?
    @Published var selectedLeftovers: Set<URL> = []
    @Published var selectedOrphans: Set<URL> = []
    @Published var query = ""

    var filteredApplications: [InstalledApplication] {
        applications.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
    }
    var unusedApplications: [InstalledApplication] {
        let cutoff = Calendar.current.date(byAdding: .month, value: -6, to: Date()) ?? .distantPast
        return filteredApplications.filter { ($0.lastUsed ?? .distantFuture) < cutoff }
    }
    var filteredOrphans: [AppLeftover] {
        orphanedLeftovers.filter {
            query.isEmpty
                || $0.url.lastPathComponent.localizedCaseInsensitiveContains(query)
                || $0.kind.localizedCaseInsensitiveContains(query)
        }
    }
    var selectedApp: InstalledApplication? {
        applications.first { $0.url == selectedAppURL }
    }
    var selectedLeftoverItems: [AppLeftover] {
        leftovers.filter { selectedLeftovers.contains($0.url) }
    }
    var selectedBytes: Int64 {
        (selectedApp?.size ?? 0) + selectedLeftoverItems.reduce(0) { $0 + $1.size }
    }

    func scanApplications() async {
        scanningApps = true
        applications = await ApplicationScanner.installedApplications()
        scanningApps = false
    }

    func scanOrphanedLeftovers() async {
        guard !scanningOrphans else { return }
        scanningOrphans = true
        result = nil
        if applications.isEmpty {
            applications = await ApplicationScanner.installedApplications()
        }
        orphanedLeftovers = await ApplicationScanner.orphanedLeftovers(
            installedApplications: applications
        )
        selectedOrphans = []
        scanningOrphans = false
    }

    func select(_ app: InstalledApplication) async {
        selectedAppURL = app.url
        leftovers = []
        selectedLeftovers = []
        result = nil
        scanningLeftovers = true
        leftovers = await ApplicationScanner.leftovers(for: app)
        selectedLeftovers = Set(
            leftovers
                .filter { $0.match == .exact && !$0.requiresAdministrator }
                .map(\.url)
        )
        scanningLeftovers = false
    }

    func uninstall() async {
        guard let app = selectedApp else { return }
        let selected = selectedLeftoverItems
        uninstalling = true
        result = await Task.detached(priority: .userInitiated) {
            ApplicationScanner.uninstall(app, leftovers: selected)
        }.value
        uninstalling = false
        if result?.succeeded == true {
            selectedAppURL = nil
            leftovers = []
            selectedLeftovers = []
            await scanApplications()
        }
    }

    func trashSelectedOrphans() async {
        let selected = orphanedLeftovers.filter { selectedOrphans.contains($0.url) }
        guard !selected.isEmpty else { return }
        trashingOrphans = true
        let sizes = Dictionary(uniqueKeysWithValues: selected.map { ($0.url, $0.size) })
        let outcome = await Task.detached(priority: .userInitiated) {
            FileActions.trash(selected.map(\.url), sizes: sizes)
        }.value
        let failed = Set(outcome.failed)
        orphanedLeftovers.removeAll {
            selectedOrphans.contains($0.url) && !failed.contains($0.url)
        }
        selectedOrphans = failed
        result = MaintenanceResult(
            succeeded: failed.isEmpty,
            message: failed.isEmpty
                ? "Moved \(outcome.freed.formattedBytes) to Trash."
                : "\(failed.count) item\(failed.count == 1 ? "" : "s") could not be moved to Trash."
        )
        trashingOrphans = false
    }
}

struct UninstallerView: View {
    private enum Section: String, CaseIterable, Identifiable {
        case applications = "Applications"
        case unused = "Unused"
        case leftovers = "Leftovers"

        var id: String { rawValue }
    }

    @StateObject private var vm = UninstallerViewModel()
    @State private var confirming = false
    @State private var confirmingOrphans = false
    @State private var section: Section = .applications
    private let theme = Module.uninstaller.theme

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(
                title: "Uninstaller",
                subtitle: "Remove apps, reviewed related files, and strict orphaned bundle-ID leftovers."
            ) {
                Button { Task { await vm.scanApplications() } } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .buttonStyle(GradientButtonStyle(colors: theme.colors, prominent: false))
            }

            Picker("Uninstaller section", selection: $section) {
                ForEach(Section.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 390)
            .padding(.bottom, 12)

            if section == .leftovers {
                orphanedLeftovers
            } else {
                HSplitView {
                    appList(section == .unused ? vm.unusedApplications : vm.filteredApplications)
                        .frame(minWidth: 280, idealWidth: 330)
                    detail.frame(minWidth: 430)
                }
                .padding(.horizontal, 18).padding(.bottom, 18)
            }
        }
        .task { if vm.applications.isEmpty { await vm.scanApplications() } }
        .onChange(of: section) { _, newValue in
            vm.selectedAppURL = nil
            if newValue == .leftovers, vm.orphanedLeftovers.isEmpty {
                Task { await vm.scanOrphanedLeftovers() }
            }
        }
        .confirmationDialog(
            "Uninstall \(vm.selectedApp?.name ?? "application")?",
            isPresented: $confirming,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) { Task { await vm.uninstall() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(vm.selectedBytes.formattedBytes) across the app and \(vm.selectedLeftoverItems.count) reviewed related items will be moved to Trash.")
        }
        .confirmationDialog(
            "Move \(vm.selectedOrphans.count) orphaned item"
                + "\(vm.selectedOrphans.count == 1 ? "" : "s") to Trash?",
            isPresented: $confirmingOrphans,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                Task { await vm.trashSelectedOrphans() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("These names look like bundle identifiers with no installed application. Review every checked item before removal.")
        }
    }

    private func appList(_ applications: [InstalledApplication]) -> some View {
        VStack(spacing: 10) {
            TextField("Filter applications", text: $vm.query).textFieldStyle(.roundedBorder)
            if vm.scanningApps {
                Spacer()
                ProgressView("Reading Applications…")
                Spacer()
            } else if applications.isEmpty {
                Spacer()
                Image(systemName: section == .unused ? "clock.badge.checkmark" : "shippingbox")
                    .font(.system(size: 36)).foregroundStyle(.secondary)
                Text(section == .unused ? "No unused apps found" : "No applications found")
                    .font(.headline)
                if section == .unused {
                    Text("Only apps with a recorded last-use date older than six months appear here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                Spacer()
            } else {
                List(applications) { app in
                    Button {
                        Task { await vm.select(app) }
                    } label: {
                        HStack(spacing: 10) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                                .resizable().frame(width: 34, height: 34)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(app.name).fontWeight(.medium).lineLimit(1)
                                Text(app.size.formattedBytes).font(.caption).foregroundStyle(.secondary)
                                if section == .unused, let lastUsed = app.lastUsed {
                                    Text("Last used \(lastUsed.formatted(date: .abbreviated, time: .omitted))")
                                        .font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                            Spacer()
                        }
                        .padding(.vertical, 3)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(vm.selectedAppURL == app.url ? theme.accent.opacity(0.16) : Color.clear)
                }
                .scrollContentBackground(.hidden)
            }
        }
        .padding(12)
        .cardStyle()
    }

    @ViewBuilder private var detail: some View {
        if let app = vm.selectedApp {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                        .resizable().frame(width: 56, height: 56)
                    VStack(alignment: .leading) {
                        Text(app.name).font(.title2).fontWeight(.semibold)
                        Text([app.version, app.bundleIdentifier].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                        if let lastUsed = app.lastUsed {
                            Text("Last used \(lastUsed.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let teamIdentifier = app.teamIdentifier {
                            Text("Signing team \(teamIdentifier)")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
                Divider()
                Text("Related files").font(.headline)
                if vm.scanningLeftovers {
                    ProgressView("Checking exact bundle-ID matches…")
                } else if vm.leftovers.isEmpty {
                    Text("No related files matched this app's bundle identifier.")
                        .foregroundStyle(.secondary)
                } else {
                    List {
                        ForEach(vm.leftovers, id: \.url) { (leftover: AppLeftover) in
                            Toggle(isOn: Binding(
                                get: { vm.selectedLeftovers.contains(leftover.url) },
                                set: { enabled in
                                    if enabled { vm.selectedLeftovers.insert(leftover.url) }
                                    else { vm.selectedLeftovers.remove(leftover.url) }
                                }
                            )) {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(leftover.url.lastPathComponent).lineLimit(1)
                                        Text(leftover.kind).font(.caption).foregroundStyle(.secondary)
                                        Text(leftover.match.rawValue
                                            + (leftover.requiresAdministrator ? " · Administrator" : ""))
                                            .font(.caption2)
                                            .foregroundStyle(
                                                leftover.match == .exact && !leftover.requiresAdministrator
                                                    ? Color.secondary.opacity(0.7)
                                                    : Color.orange
                                            )
                                    }
                                    Spacer()
                                    Text(leftover.size.formattedBytes).monospacedDigit().foregroundStyle(.secondary)
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
                Spacer()
                if let result = vm.result {
                    Label(result.message, systemImage: result.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(result.succeeded ? .green : .red)
                }
                HStack {
                    Text("\(vm.selectedBytes.formattedBytes) selected")
                        .foregroundStyle(.secondary)
                    Spacer()
                    if vm.uninstalling {
                        ProgressView()
                    } else {
                        Button("Uninstall") { confirming = true }
                            .buttonStyle(GradientButtonStyle(colors: theme.colors))
                            .disabled(!app.canUninstall)
                    }
                }
            }
            .padding(18)
            .cardStyle()
        } else {
            VStack(spacing: 10) {
                Image(systemName: "shippingbox").font(.system(size: 44)).foregroundStyle(.secondary)
                Text("Select an application").font(.title3).fontWeight(.semibold)
                Text("Mewp will find strict bundle-ID matches for review.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .cardStyle()
        }
    }

    private var orphanedLeftovers: some View {
        VStack(spacing: 12) {
            HStack {
                TextField("Filter orphaned files", text: $vm.query)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 340)
                Spacer()
                Button("Rescan") { Task { await vm.scanOrphanedLeftovers() } }
                    .buttonStyle(GradientButtonStyle(colors: theme.colors, prominent: false))
                    .disabled(vm.scanningOrphans)
            }

            if vm.scanningOrphans {
                Spacer()
                ProgressView("Checking strict bundle-ID names…")
                Spacer()
            } else if vm.filteredOrphans.isEmpty {
                Spacer()
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 44)).foregroundStyle(.secondary)
                Text("No orphaned bundle-ID files found")
                    .font(.title3).fontWeight(.semibold)
                Text("This scan intentionally ignores Apple files and names that are not strict bundle identifiers.")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List(vm.filteredOrphans, id: \.url) { (leftover: AppLeftover) in
                    Toggle(isOn: Binding(
                        get: { vm.selectedOrphans.contains(leftover.url) },
                        set: { enabled in
                            if enabled { vm.selectedOrphans.insert(leftover.url) }
                            else { vm.selectedOrphans.remove(leftover.url) }
                        }
                    )) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(leftover.url.lastPathComponent).lineLimit(1)
                                Text("\(leftover.kind) · \(leftover.url.deletingLastPathComponent().path)")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            Text(leftover.size.formattedBytes)
                                .monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
                .tableCard()
            }

            HStack {
                Text("\(vm.orphanedLeftovers.count) candidates")
                    .foregroundStyle(.secondary)
                Spacer()
                if vm.trashingOrphans {
                    ProgressView()
                } else {
                    Button("Move selected to Trash") { confirmingOrphans = true }
                        .buttonStyle(GradientButtonStyle(colors: theme.colors))
                        .disabled(vm.selectedOrphans.isEmpty)
                }
            }
        }
        .padding(.horizontal, 18).padding(.bottom, 18)
    }
}
