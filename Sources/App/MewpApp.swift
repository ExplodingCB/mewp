import SwiftUI

@main
struct MewpApp: App {
    @StateObject private var permissions = PermissionsModel()
    @StateObject private var monitor = SystemMonitorModel()
    @StateObject private var navigation = AppNavigationModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(permissions)
                .environmentObject(monitor)
                .environmentObject(navigation)
                .frame(minWidth: 900, minHeight: 600)
                .task { monitor.start() }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1040, height: 680)

        MenuBarExtra {
            MenuBarMonitorView()
                .environmentObject(monitor)
                .environmentObject(navigation)
        } label: {
            Label("Mewp", systemImage: "pawprint.fill")
        }
        .menuBarExtraStyle(.window)
    }
}
