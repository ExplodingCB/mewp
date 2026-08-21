import SwiftUI

struct CleanupView: View {
    @ObservedObject var vm: CleanupViewModel
    @EnvironmentObject private var permissions: PermissionsModel
    @State private var confirmingClean = false

    private let theme = Module.cleanup.theme

    var body: some View {
        VStack(spacing: 0) {
            header
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if vm.hasResults {
                actionBar
            }
        }
        .onAppear { permissions.refresh() }
    }

    // MARK: - Header

    private var header: some View {
        ModuleHeader(title: "Cleanup",
                     subtitle: "Reclaim space from caches, logs, and other regenerable junk.") {
            if vm.hasResults {
                Button {
                    Task { await vm.scan(fullDiskAccessGranted: permissions.fullDiskAccessGranted) }
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .buttonStyle(GradientButtonStyle(colors: theme.colors, prominent: false))
            }
        }
    }

    // MARK: - Content states

    @ViewBuilder private var content: some View {
        switch vm.phase {
        case .idle:
            idleState
        case .scanning:
            scanningState
        default:
            resultsList
        }
    }

    private var idleState: some View {
        VStack(spacing: 28) {
            BigScanButton(title: "Scan", systemImage: "sparkles", theme: theme) {
                Task { await vm.scan(fullDiskAccessGranted: permissions.fullDiskAccessGranted) }
            }
            VStack(spacing: 6) {
                Text("Scan for junk").font(.title3).fontWeight(.semibold)
                Text("CleanMyMewp looks through caches, logs, developer junk, and the\nTrash to find space you can safely reclaim.")
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if !permissions.fullDiskAccessGranted {
                fdaHint
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var scanningState: some View {
        ScanningIndicator(theme: theme, status: vm.scanStatus)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var resultsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if vm.needsFullDiskAccessForSome && !permissions.fullDiskAccessGranted {
                    fdaBanner
                }
                ForEach(Array(vm.results.enumerated()), id: \.element.id) { index, result in
                    CategoryCard(vm: vm, result: result)
                        .staggeredAppear(index)
                }
                Color.clear.frame(height: 8)
            }
            .padding(20)
        }
    }

    // MARK: - Full Disk Access affordances

    private var fdaHint: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.fill").foregroundStyle(.orange)
            Text("Grant Full Disk Access to also scan Trash, Mail, and iOS backups.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Open Settings") { FullDiskAccess.openSystemSettings() }
                .buttonStyle(.link).font(.caption)
        }
        .padding(.top, 6)
    }

    private var fdaBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.fill").foregroundStyle(.orange).font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text("Some categories are locked").fontWeight(.semibold)
                Text("Trash, Mail cache, and iOS backups need Full Disk Access.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open Settings") { FullDiskAccess.openSystemSettings() }
        }
        .padding(14)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.orange.opacity(0.25), lineWidth: 1)
        }
    }

    // MARK: - Action bar

    private var actionBar: some View {
        HStack(spacing: 16) {
            Toggle(isOn: $vm.permanentDelete) {
                Text("Delete permanently")
            }
            .toggleStyle(.checkbox)
            .help("Off: removable items go to Trash. Emptying Trash is always permanent. On: every selected item is deleted permanently.")

            Spacer()

            switch vm.phase {
            case .cleaning:
                HStack(spacing: 10) {
                    ProgressView(value: vm.cleanProgress).frame(width: 160)
                    Text("Cleaning…").foregroundStyle(.secondary)
                }
            case .done(let summary):
                doneSummary(summary)
            default:
                VStack(alignment: .trailing, spacing: 1) {
                    Text("\(vm.selectedBytes.formattedBytes) selected")
                        .fontWeight(.semibold)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(Motion.readout, value: vm.selectedBytes)
                    Text("\(vm.selectedCount) item\(vm.selectedCount == 1 ? "" : "s") of \(vm.totalFoundBytes.formattedBytes) found")
                        .font(.caption).foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                        .animation(Motion.readout, value: vm.selectedCount)
                }
                Button {
                    confirmingClean = true
                } label: {
                    Text(vm.willPermanentlyDeleteAnything ? "Review & Clean" : "Clean").frame(minWidth: 90)
                }
                .buttonStyle(GradientButtonStyle(colors: theme.colors))
                .disabled(vm.selectedCount == 0)
                .opacity(vm.selectedCount == 0 ? 0.5 : 1)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(.bar)
        .overlay(alignment: .top) { Divider().opacity(0.5) }
        .confirmationDialog(confirmationTitle, isPresented: $confirmingClean, titleVisibility: .visible) {
            Button(vm.willPermanentlyDeleteAnything ? "Clean Selected Items" : "Move to Trash",
                   role: .destructive) {
                Task { await vm.clean() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(cleanupConfirmationMessage)
        }
    }

    private var confirmationTitle: String {
        "\(vm.willPermanentlyDeleteAnything ? "Review cleaning" : "Clean") \(vm.selectedBytes.formattedBytes)?"
    }

    private var cleanupConfirmationMessage: String {
        if vm.permanentDelete {
            if vm.selectedIncludesAdministratorItems {
                return "Selected user items will be permanently deleted. Reviewed /Library items will trigger an administrator prompt and move to Trash."
            }
            return "Every selected item will be permanently deleted. This cannot be undone."
        }
        if vm.selectedIncludesPermanentItems {
            return "Trash contents will be permanently deleted. Other selected items will be moved to Trash."
        }
        if vm.selectedIncludesAdministratorItems {
            return "Reviewed /Library items will trigger an administrator prompt and move to Trash. Other selected items will also move to Trash."
        }
        return "Selected items will be moved to Trash so they can be restored."
    }

    private func doneSummary(_ summary: CleanupViewModel.DeletionOutcomeSummary) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 1) {
                Text("Freed \(summary.freedBytes.formattedBytes)").fontWeight(.semibold)
                Text("\(summary.deletedCount) item(s) removed"
                     + (summary.failureCount > 0 ? " · \(summary.failureCount) skipped" : ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if vm.selectedCount > 0 {
                Button("Clean More") { confirmingClean = true }
                    .buttonStyle(GradientButtonStyle(colors: theme.colors))
            }
        }
    }
}
