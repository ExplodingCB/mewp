import Foundation
import AppKit

/// Result of a cleanup run.
struct DeletionOutcome: Sendable {
    var freedBytes: Int64 = 0
    var deletedCount: Int = 0
    var failures: [String] = []   // human-readable "path — reason"
    var failedItemURLs: Set<URL> = []
}

/// Which running apps hold a bundle id, so we can refuse to nuke live caches.
enum RunningApps {
    static func isRunning(bundleID: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier?.caseInsensitiveCompare(bundleID) == .orderedSame
        }
    }
}

/// Removes junk items. Default is reversible (move to Trash); `permanent` unlinks
/// immediately to reclaim space now. `~/.Trash` contents are always permanent
/// (you can't trash the Trash). Runs synchronously — call it off the main actor.
enum Deleter {

    static func run(
        _ items: [JunkItem],
        permanent: Bool,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) -> DeletionOutcome {
        var outcome = DeletionOutcome()
        let total = max(1, items.count)

        for (index, item) in items.enumerated() {
            switch item.strategy {
            case .moveItemToTrash:
                removeOne(item.url, permanent: permanent, size: item.size, into: &outcome)
            case .emptyContentsToTrash:
                emptyContents(of: item.url, permanent: permanent, declaredSize: item.size,
                              itemURL: item.url, into: &outcome)
            case .emptyContentsPermanent:
                emptyContents(of: item.url, permanent: true, declaredSize: item.size,
                              itemURL: item.url, into: &outcome)
            }
            onProgress?(Double(index + 1) / Double(total))
        }
        return outcome
    }

    // MARK: - Internals

    private static func removeOne(_ url: URL, permanent: Bool, size: Int64, into outcome: inout DeletionOutcome) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        do {
            if permanent {
                try fm.removeItem(at: url)
            } else {
                try fm.trashItem(at: url, resultingItemURL: nil)
            }
            outcome.freedBytes += size
            outcome.deletedCount += 1
        } catch {
            outcome.failures.append("\(url.path) — \(error.localizedDescription)")
            outcome.failedItemURLs.insert(url)
        }
    }

    private static func emptyContents(
        of dir: URL,
        permanent: Bool,
        declaredSize: Int64,
        itemURL: URL,
        into outcome: inout DeletionOutcome
    ) {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            outcome.failures.append("\(dir.path) — Could not read the folder.")
            outcome.failedItemURLs.insert(itemURL)
            return
        }
        var anyFailed = false
        var removed = 0
        for child in children {
            do {
                if permanent {
                    try fm.removeItem(at: child)
                } else {
                    try fm.trashItem(at: child, resultingItemURL: nil)
                }
                removed += 1
            } catch {
                anyFailed = true
                outcome.failures.append("\(child.path) — \(error.localizedDescription)")
                outcome.failedItemURLs.insert(itemURL)
            }
        }
        // Credit the declared size only if we cleared everything; otherwise we
        // can't cleanly attribute partial bytes, so count the items instead.
        if removed > 0 {
            outcome.deletedCount += removed
            if !anyFailed { outcome.freedBytes += declaredSize }
        }
    }
}
