import Foundation

/// Expands the safety ruleset into concrete, sized `JunkItem`s. Concurrency: each
/// discovered item is measured on a bounded task group so a big cache tree doesn't
/// stall the others. Pure/read-only — it never deletes anything.
enum JunkScanner {

    /// Scans every category. `fullDiskAccessGranted` gates the TCC categories.
    static func scanAll(fullDiskAccessGranted: Bool) async -> [CategoryScanResult] {
        let categories = SafetyRules.categories()
        return await concurrentMap(categories, limit: min(3, max(2, categories.count))) {
            category in
            await scan(category, fullDiskAccessGranted: fullDiskAccessGranted)
        }
    }

    static func scan(_ category: CleanupCategory, fullDiskAccessGranted: Bool) async -> CategoryScanResult {
        if category.permission == .fullDiskAccess && !fullDiskAccessGranted {
            return CategoryScanResult(category: category, items: [], lockedByPermission: true)
        }

        // 1) Gather candidate URLs (cheap, no recursion yet).
        var candidates: [(url: URL, strategy: DeleteStrategy, isDir: Bool, name: String)] = []
        var note: String?

        for source in category.sources {
            if let running = source.requireAppNotRunning.first(where: { RunningApps.isRunning(bundleID: $0) }) {
                note = "Quit \(appName(for: running)) to clean this."
                continue
            }
            candidates.append(contentsOf: expand(source))
        }

        // 2) Measure sizes concurrently.
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let measured = await concurrentMap(candidates, limit: min(4, max(2, cores))) { c in
            (c, DirectoryScanner.measure(c.url))
        }

        // 3) Keep only non-empty items.
        let items: [JunkItem] = measured.compactMap { (c, size) in
            guard size.allocatedBytes > 0 else { return nil }
            return JunkItem(url: c.url,
                            displayName: prettyName(c.name, url: c.url),
                            size: size.allocatedBytes,
                            isDirectory: c.isDir,
                            strategy: c.strategy,
                            categoryID: category.id,
                            requiresAdministrator: category.permission == .admin)
        }
        .sorted { $0.size > $1.size }

        return CategoryScanResult(category: category, items: items, note: note)
    }

    // MARK: - Source expansion

    private static func expand(_ source: JunkSource) -> [(url: URL, strategy: DeleteStrategy, isDir: Bool, name: String)] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: source.root.path, isDirectory: &isDir) else { return [] }

        switch source.mode {
        case .childrenAsItems:
            return DirectoryScanner.children(of: source.root).compactMap { child in
                let name = child.lastPathComponent
                if source.skipNames.contains(name) { return nil }
                let childIsDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? true
                return (child, source.strategy, childIsDir, name)
            }

        case .folderContents:
            // One item representing the container; size is its contents.
            return [(source.root, source.strategy, true, source.root.lastPathComponent)]

        case let .matchingFiles(extensions, recursive):
            return matchingFiles(under: source.root, extensions: extensions, recursive: recursive)
                .map { ($0, source.strategy, false, $0.lastPathComponent) }

        case let .childSubfolders(relativePath):
            return DirectoryScanner.children(of: source.root).compactMap { child in
                let target = child.appendingPathComponent(relativePath)
                var targetIsDirectory: ObjCBool = false
                guard
                    fm.fileExists(atPath: target.path, isDirectory: &targetIsDirectory),
                    targetIsDirectory.boolValue
                else { return nil }
                return (target, source.strategy, true, child.lastPathComponent)
            }
        }
    }

    private static func matchingFiles(under root: URL, extensions: Set<String>, recursive: Bool) -> [URL] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey]
        if recursive {
            guard let en = fm.enumerator(at: root, includingPropertiesForKeys: keys) else { return [] }
            return en.compactMap { $0 as? URL }.filter { matches($0, extensions) }
        } else {
            let kids = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: keys)) ?? []
            return kids.filter { matches($0, extensions) }
        }
    }

    private static func matches(_ url: URL, _ extensions: Set<String>) -> Bool {
        let isFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
        return isFile && extensions.contains(url.pathExtension.lowercased())
    }

    // MARK: - Display helpers

    /// For a folder-contents item, show the folder path; for per-child items,
    /// try to resolve a bundle id like "com.apple.Safari" to a friendly name.
    private static func prettyName(_ raw: String, url: URL) -> String {
        if raw.contains(".") && raw.split(separator: ".").count >= 3 {
            // Looks like a bundle id — surface a cleaner tail.
            return raw
        }
        return raw
    }

    private static func appName(for bundleID: String) -> String {
        // Cheap map for the few we guard; falls back to the id.
        switch bundleID {
        case "com.apple.mail": return "Mail"
        case "com.apple.Safari": return "Safari"
        case "com.google.Chrome": return "Google Chrome"
        case "org.mozilla.firefox": return "Firefox"
        default: return bundleID
        }
    }
}
