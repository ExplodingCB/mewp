import Foundation

/// Lightweight metadata for one file. Used by Large & Old and the duplicate
/// finder, which want a flat list, not a tree.
struct FileEntry: Identifiable, Sendable, Hashable {
    var url: URL
    /// Allocated bytes reclaimed by deleting the file.
    var size: Int64
    /// Logical content length used for byte-for-byte duplicate matching.
    var logicalSize: Int64
    var modified: Date?
    var accessed: Date?

    var id: URL { url }
    static func == (a: FileEntry, b: FileEntry) -> Bool { a.url == b.url }
    func hash(into hasher: inout Hasher) { hasher.combine(url) }
}

/// Flat recursive enumeration of regular files under a root, filtered by a
/// minimum size up front so huge trees don't balloon in memory.
enum FileWalker {

    private static let keys: Set<URLResourceKey> = [
        .isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey,
        .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey,
        .contentModificationDateKey, .contentAccessDateKey,
    ]

    private static let skipDirs: Set<String> = [
        ".Trash", ".Spotlight-V100", ".fseventsd", ".DocumentRevisions-V100", ".TemporaryItems",
    ]

    static func collect(
        root: URL,
        minSize: Int64 = 0,
        useLogicalSizeForMinimum: Bool = false,
        isCancelled: @escaping @Sendable () -> Bool = { false },
        onProgress: @escaping @Sendable (_ visited: Int, _ currentName: String) -> Void = { _, _ in }
    ) -> [FileEntry] {
        var out: [FileEntry] = []
        var visited = 0
        let fm = FileManager.default
        guard let en = fm.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { return out }

        for case let url as URL in en {
            if isCancelled() { break }
            visited += 1
            if visited.isMultiple(of: 256) {
                onProgress(visited, url.lastPathComponent)
            }
            guard let v = try? url.resourceValues(forKeys: keys) else { continue }
            if v.isDirectory == true {
                if skipDirs.contains(url.lastPathComponent) { en.skipDescendants() }
                continue
            }
            if v.isSymbolicLink == true || v.isRegularFile != true { continue }
            let logicalSize = Int64(v.fileSize ?? 0)
            let allocatedSize = Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? v.fileSize ?? 0)
            let filterSize = useLogicalSizeForMinimum ? logicalSize : allocatedSize
            if filterSize < minSize { continue }
            out.append(FileEntry(url: url, size: allocatedSize, logicalSize: logicalSize,
                                 modified: v.contentModificationDate,
                                 accessed: v.contentAccessDate))
        }
        onProgress(visited, "")
        return out
    }

    /// Scans independent top-level subtrees concurrently. This keeps the same
    /// metadata and package rules as `collect` while avoiding a single serial
    /// enumerator for large home folders and external drives.
    static func collectParallel(
        root: URL,
        minSize: Int64 = 0,
        useLogicalSizeForMinimum: Bool = false,
        isCancelled: @escaping @Sendable () -> Bool = { false },
        onProgress: @escaping @Sendable (_ visited: Int, _ currentName: String) -> Void = { _, _ in }
    ) async -> [FileEntry] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
            return []
        }
        if !isDirectory.boolValue {
            return entry(
                for: root,
                minSize: minSize,
                useLogicalSizeForMinimum: useLogicalSizeForMinimum
            ).map { [$0] } ?? []
        }

        let children = DirectoryScanner.children(of: root)
        let progress = FileWalkProgress(onProgress: onProgress)
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let batches: [[FileEntry]] = await concurrentMap(
            children,
            limit: min(8, max(2, cores))
        ) { child -> [FileEntry] in
            if isCancelled() { return [] }
            let values = try? child.resourceValues(forKeys: keys)
            if values?.isSymbolicLink == true { return [] }
            if values?.isDirectory != true {
                progress.add(1, currentName: child.lastPathComponent)
                return entry(
                    for: child,
                    minSize: minSize,
                    useLogicalSizeForMinimum: useLogicalSizeForMinimum
                ).map { [$0] } ?? []
            }

            let subtreeID = UUID()
            let entries = collect(
                root: child,
                minSize: minSize,
                useLogicalSizeForMinimum: useLogicalSizeForMinimum,
                isCancelled: isCancelled
            ) { visited, currentName in
                progress.updateSubtree(
                    subtreeID,
                    visited: visited,
                    currentName: currentName
                )
            }
            return entries
        }
        progress.finish()
        return batches.flatMap { $0 }
    }

    private static func entry(
        for url: URL,
        minSize: Int64,
        useLogicalSizeForMinimum: Bool
    ) -> FileEntry? {
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        guard values.isSymbolicLink != true, values.isRegularFile == true else { return nil }
        let logicalSize = Int64(values.fileSize ?? 0)
        let allocatedSize = Int64(
            values.totalFileAllocatedSize
                ?? values.fileAllocatedSize
                ?? values.fileSize
                ?? 0
        )
        let filterSize = useLogicalSizeForMinimum ? logicalSize : allocatedSize
        guard filterSize >= minSize else { return nil }
        return FileEntry(
            url: url,
            size: allocatedSize,
            logicalSize: logicalSize,
            modified: values.contentModificationDate,
            accessed: values.contentAccessDate
        )
    }
}

private final class FileWalkProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var visited = 0
    private var subtreeVisited: [UUID: Int] = [:]
    private let callback: @Sendable (Int, String) -> Void

    init(onProgress: @escaping @Sendable (Int, String) -> Void) {
        callback = onProgress
    }

    func add(_ amount: Int, currentName: String) {
        lock.lock()
        visited += amount
        let current = visited
        lock.unlock()
        callback(current, currentName)
    }

    func finish() {
        lock.lock()
        let current = visited
        lock.unlock()
        callback(current, "")
    }

    func updateSubtree(_ id: UUID, visited newValue: Int, currentName: String) {
        lock.lock()
        let previous = subtreeVisited[id, default: 0]
        subtreeVisited[id] = newValue
        visited += max(0, newValue - previous)
        let current = visited
        lock.unlock()
        callback(current, currentName)
    }
}
