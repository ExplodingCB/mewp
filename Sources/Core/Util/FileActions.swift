import Foundation
import AppKit

/// Shared user-facing file operations for the browsing modules (Space Map,
/// Large Files, Duplicates). Trash-first, like the Cleanup module.
enum FileActions {

    static func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Moves urls to the Trash. Returns bytes freed (best-effort from sizes) and
    /// any that failed. Runs synchronously — call off the main actor for big sets.
    @discardableResult
    static func trash(_ urls: [URL], sizes: [URL: Int64] = [:]) -> (freed: Int64, failed: [URL]) {
        var freed: Int64 = 0
        var failed: [URL] = []
        let fm = FileManager.default
        for url in urls {
            do {
                try fm.trashItem(at: url, resultingItemURL: nil)
                freed += sizes[url] ?? Int64(DirectoryScanner.allocatedSize(ofItem: url))
            } catch {
                failed.append(url)
            }
        }
        return (freed, failed)
    }

    /// Home directory, the sensible default scan root.
    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// Prompts for a folder to scan (used by the browsing modules).
    @MainActor
    static func chooseFolder(message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        panel.message = message
        panel.directoryURL = home
        return panel.runModal() == .OK ? panel.url : nil
    }
}

/// Free-space figures for a volume. `important` matches what Finder reports
/// (includes purgeable); `available` matches `df`. They differ because of APFS
/// snapshots, caches, and evictable iCloud content.
struct VolumeSpace: Sendable {
    var total: Int64
    var available: Int64
    var important: Int64

    static func forRoot(_ url: URL) -> VolumeSpace? {
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ]
        guard let v = try? url.resourceValues(forKeys: keys) else { return nil }
        return VolumeSpace(
            total: Int64(v.volumeTotalCapacity ?? 0),
            available: Int64(v.volumeAvailableCapacity ?? 0),
            important: v.volumeAvailableCapacityForImportantUsage ?? 0
        )
    }
}
