import SwiftUI

/// Top-level module list.
enum Module: String, CaseIterable, Identifiable {
    case smartCare = "Smart Care"
    case cleanup = "Cleanup"
    case spaceLens = "Space Lens"
    case largeOld = "Large & Old Files"
    case duplicates = "Duplicates"
    case uninstaller = "Uninstaller"
    case similarImages = "Similar Images"
    case performance = "Performance"
    case startupItems = "Startup Items"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .smartCare: return "checkmark.shield"
        case .cleanup: return "sparkles"
        case .spaceLens: return "chart.pie"
        case .largeOld: return "tray.full"
        case .duplicates: return "square.on.square"
        case .uninstaller: return "trash.slash"
        case .similarImages: return "photo.on.rectangle.angled"
        case .performance: return "gauge.with.dots.needle.67percent"
        case .startupItems: return "power"
        }
    }
}

@MainActor
final class AppNavigationModel: ObservableObject {
    @Published var selection: Module = .smartCare
    @Published private(set) var smartCareScanPending = false

    func requestSmartCareScan() {
        selection = .smartCare
        smartCareScanPending = true
    }

    func consumeSmartCareScanRequest() {
        smartCareScanPending = false
    }
}

struct RootView: View {
    @EnvironmentObject private var permissions: PermissionsModel
    @EnvironmentObject private var navigation: AppNavigationModel
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var cleanupVM = CleanupViewModel()

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
                .safeAreaInset(edge: .bottom) { sidebarFooter }
        } detail: {
            detail
                .background(AuroraBackground(theme: navigation.selection.theme))
        }
        .frame(minWidth: 900, minHeight: 600)
        .tint(navigation.selection.theme.accent)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { permissions.refresh() }
        }
    }

    /// A `List` with no selection binding.
    ///
    /// macOS draws `List` sidebar selection with the system accent colour from System
    /// Settings — blue on a default Mac — which fought every module's own accent. Omitting
    /// the binding means the system never draws a highlight, so each row can tint itself
    /// with its own module colour instead.
    ///
    /// It has to stay a `List`: that is what supplies the sidebar material and the top
    /// safe-area inset under the hidden title bar. A plain `ScrollView` here let the rows
    /// slide up beneath the window controls.
    private var sidebar: some View {
        List(Module.allCases, selection: $navigation.selection) { module in
            HStack(spacing: 10) {
                IconTile(systemImage: module.systemImage, colors: module.theme.colors, size: 24)
                Text(module.rawValue)
                    .font(.system(size: 13, weight: .medium))
            }
            .padding(.vertical, 3)
            .tag(module)
        }
    }

    @ViewBuilder private var detail: some View {
        switch navigation.selection {
        case .smartCare:
            SmartCareView()
                .environmentObject(permissions)
        case .cleanup:
            CleanupView(vm: cleanupVM)
                .environmentObject(permissions)
        case .spaceLens:
            SpaceLensView()
        case .largeOld:
            LargeOldView()
        case .duplicates:
            DuplicatesView()
        case .uninstaller:
            UninstallerView()
        case .similarImages:
            SimilarImagesView()
        case .performance:
            PerformanceView()
        case .startupItems:
            StartupItemsView()
        }
    }

    /// One sidebar entry. The selected row gets a tinted pill plus a leading accent bar,
    /// so the module's identity carries into the navigation rather than being overridden
    /// by the system highlight.
    private struct SidebarModuleRow: View {
        let module: Module
        let isSelected: Bool
        let select: () -> Void

        @State private var hovering = false

        var body: some View {
            let accent = module.theme.accent
            Button(action: select) {
                HStack(spacing: 10) {
                    IconTile(systemImage: module.systemImage, colors: module.theme.colors, size: 24)
                    Text(module.rawValue)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? AnyShapeStyle(accent) : AnyShapeStyle(.primary))
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 7)
                .padding(.horizontal, 8)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(accent.opacity(isSelected ? 0.18 : (hovering ? 0.09 : 0)))
                }
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(accent)
                        .frame(width: 3, height: isSelected ? 18 : 0)
                        .offset(x: -4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(Motion.snappy, value: isSelected)
            .animation(Motion.snappy, value: hovering)
        }
    }

    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack(spacing: 8) {
                Image(systemName: permissions.fullDiskAccessGranted ? "lock.open.fill" : "lock.fill")
                    .foregroundStyle(permissions.fullDiskAccessGranted ? .green : .orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Full Disk Access")
                        .font(.caption).fontWeight(.medium)
                    Text(permissions.fullDiskAccessGranted ? "Granted" : "Not granted")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                if !permissions.fullDiskAccessGranted {
                    Button("Grant") { FullDiskAccess.openSystemSettings() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
        .onAppear { permissions.refresh() }
    }
}
