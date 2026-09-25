#if DEBUG
import AppKit
import ScreenCaptureKit

/// Debug builds only: renders the main window to a PNG for README screenshots, without
/// needing Screen Recording permission.
///
///     MEWP_MODULE="Space Map" MEWP_SNAPSHOT=/tmp/shot.png MEWP_APPEARANCE=dark \
///       build/Build/Products/Debug/Mewp.app/Contents/MacOS/Mewp
///
/// `MEWP_SNAPSHOT_DELAY` (seconds, default 4) waits for the screen to settle first, and
/// `MEWP_SPACEMAP_ROOT=/System/Library` makes Space Map scan a folder on launch.
@MainActor
enum DebugSnapshot {
    static func runIfRequested(navigation: AppNavigationModel) {
        let env = ProcessInfo.processInfo.environment
        if let name = env["MEWP_MODULE"],
           let module = Module.allCases.first(where: { $0.rawValue.caseInsensitiveCompare(name) == .orderedSame }) {
            navigation.selection = module
        }
        switch env["MEWP_APPEARANCE"] {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
        guard let path = env["MEWP_SNAPSHOT"] else { return }
        let delay = Double(env["MEWP_SNAPSHOT_DELAY"] ?? "") ?? 4

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            // Same size every time so screenshots line up.
            NSApp.windows.first { $0.isVisible && $0.canBecomeMain }?.setContentSize(NSSize(width: 1040, height: 680))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            // Key window, so the traffic lights and selection show in their active colors.
            NSApp.activate()
            NSApp.windows.first { $0.isVisible && $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            Task { @MainActor in
                if let image = await captureMainWindow() {
                    let rep = NSBitmapImageRep(cgImage: image)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                }
                NSApp.terminate(nil)
            }
        }
    }

    /// ScreenCaptureKit can capture this process's own windows without Screen Recording
    /// permission, and unlike `cacheDisplay` it renders sidebar vibrancy correctly.
    private static func captureMainWindow() async -> CGImage? {
        guard #available(macOS 14.4, *) else { return nil }
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }),
              let content = try? await SCShareableContent.currentProcess,
              let scWindow = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) })
        else { return nil }
        let config = SCStreamConfiguration()
        config.width = Int(scWindow.frame.width * window.backingScaleFactor)
        config.height = Int(scWindow.frame.height * window.backingScaleFactor)
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        return try? await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: scWindow), configuration: config)
    }
}
#endif
