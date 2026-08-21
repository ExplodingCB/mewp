import Foundation
import AppKit
import Combine

/// Full Disk Access (TCC) has no request API and shows no prompt. The sanctioned
/// pattern is: try to read a known TCC-protected file; if it fails, deep-link the
/// user to the Privacy pane and poll until they flip the switch.
enum FullDiskAccess {

    /// Files that only an app with Full Disk Access can read. We only need one to
    /// succeed. Using several avoids false negatives when one happens to be absent.
    private static var probes: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db"),
            home.appendingPathComponent("Library/Safari/CloudTabs.db"),
            home.appendingPathComponent("Library/Safari/Bookmarks.plist"),
        ]
    }

    /// True if we can actually read a protected file right now.
    static func isGranted() -> Bool {
        for url in probes {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            if let handle = try? FileHandle(forReadingFrom: url) {
                defer { try? handle.close() }
                if (try? handle.read(upToCount: 1)) != nil { return true }
            }
        }
        return false
    }

    /// Opens System Settings → Privacy & Security → Full Disk Access.
    static func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        NSWorkspace.shared.open(url)
    }
}

/// Observable wrapper the UI binds to; re-checks when the app reactivates and on
/// a light poll so the switch flipping in System Settings reflects back promptly.
@MainActor
final class PermissionsModel: ObservableObject {
    @Published private(set) var fullDiskAccessGranted: Bool = FullDiskAccess.isGranted()

    private var timer: Timer?

    func refresh() {
        fullDiskAccessGranted = FullDiskAccess.isGranted()
    }

    /// Poll every 2s while the onboarding/permission UI is visible.
    func startPolling() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }
}
