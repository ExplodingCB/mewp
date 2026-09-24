import Foundation
import AppKit

/// Builds a `FileNode` tree with aggregate allocated sizes. Parallelism is at the
/// top level: each first-level entry is scanned on a bounded task group, and each
/// subtree is walked synchronously inside its task (no shared mutable state, so no
/// locks). This avoids a single serial home-folder enumerator without multiplying
/// tasks for every nested directory.
enum TreeScanner {
    /// Space Map needs the largest files, not an in-memory object for every tiny leaf.
    /// Directories remain drillable while small file leaves collapse into one read-only
    /// summary row.
    ///
    /// This was 500, which in practice meant "keep everything": almost no real folder holds
    /// more than 500 files, so the aggregation never fired and a home scan built a node per
    /// file. The bubble map can only draw a few dozen bubbles anyway.
    private static let maxVisibleFilesPerDirectory = 40

    /// How many levels below the scan root get real child nodes. Deeper directories are
    /// measured for their size and marked `isUnexpanded`, then filled in when the user
    /// actually drills into them. Trees like `node_modules`, `DerivedData` and `.git`
    /// object stores are why this cap exists.
    static let defaultMaxDepth = 5

    /// Deliberately does not fetch the modification/access dates. `FileNode` used to carry
    /// both and nothing ever read them — two `Date?` on every node in a million-node tree.
    private static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isSymbolicLinkKey,
        .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey,
    ]

    /// Directory names we never descend into: OS-managed, volatile, or firmlinked
    /// system content that would blow up the numbers or waste time.
    private static let skipDirNames: Set<String> = [
        ".Trash", ".Spotlight-V100", ".fseventsd", ".DocumentRevisions-V100",
        ".TemporaryItems", ".PKInstallSandboxManager", ".PKInstallSandboxManager-SystemSoftware",
    ]

    static func scan(
        root: URL,
        isCancelled: @escaping @Sendable () -> Bool = { false },
        onProgress: @escaping @Sendable (_ completedBytes: Int64, _ currentName: String) -> Void = { _, _ in }
    ) async -> FileNode {
        let rootNode = FileNode(url: root, isDirectory: true)
        let topLevel = DirectoryScanner.children(of: root)
        let cores = ProcessInfo.processInfo.activeProcessorCount

        let nodes: [FileNode?] = await concurrentMap(
            topLevel,
            limit: min(8, max(2, cores))
        ) { child in
            guard !isCancelled() else { return nil }
            let node = scanSync(child, depth: 1, isCancelled: isCancelled)
            if let node { onProgress(node.size, node.name) }
            return node
        }

        let kids = compactChildren(
            nodes.compactMap { $0 },
            under: root
        )
        for k in kids { k.parent = rootNode }
        rootNode.children = kids
        rootNode.size = kids.reduce(0) { $0 + $1.size }
        rootNode.fileCount = kids.reduce(0) { $0 + $1.fileCount }
        return rootNode
    }

    /// Synchronous recursive walk of one entry (file or directory subtree).
    ///
    /// - Parameter depth: Levels below the scan root. At `maxDepth` a directory is measured
    ///   rather than expanded, so the tree stops multiplying nodes.
    private static func scanSync(
        _ url: URL,
        depth: Int,
        maxDepth: Int = defaultMaxDepth,
        isCancelled: @escaping @Sendable () -> Bool
    ) -> FileNode? {
        let values = try? url.resourceValues(forKeys: Set(keys))
        if values?.isSymbolicLink == true { return nil }

        let isDir = values?.isDirectory ?? false
        if !isDir {
            let node = FileNode(url: url, isDirectory: false)
            node.size = Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? values?.fileSize ?? 0)
            node.fileCount = 1
            return node
        }

        let node = FileNode(url: url, isDirectory: true)
        if skipDirNames.contains(url.lastPathComponent) || isCancelled() { return node }

        // Past the depth budget: record how big it is, but don't build the subtree. The
        // node stays drillable — `expand(_:)` fills it in if the user goes looking.
        if depth >= maxDepth {
            let measured = DirectoryScanner.measure(url)
            node.size = measured.allocatedBytes
            node.fileCount = measured.fileCount
            node.isUnexpanded = measured.fileCount > 0
            return node
        }

        // Collapse opaque bundles (.app, .photoslibrary, .musiclibrary, .framework…)
        // into a single sized node instead of exploding their internals into the
        // map. This is both the more useful visualization and avoids needlessly
        // deep-diving TCC-protected library packages.
        if !url.pathExtension.isEmpty, NSWorkspace.shared.isFilePackage(atPath: url.path) {
            let measured = DirectoryScanner.measure(url)
            node.size = measured.allocatedBytes
            node.fileCount = measured.fileCount
            return node
        }

        var total: Int64 = 0
        var count = 0
        var childNodes: [FileNode] = []
        for child in DirectoryScanner.children(of: url) {
            if let sub = scanSync(child, depth: depth + 1, maxDepth: maxDepth, isCancelled: isCancelled) {
                childNodes.append(sub)
                total += sub.size
                count += sub.fileCount
            }
        }
        childNodes = compactChildren(childNodes, under: url)
        for c in childNodes { c.parent = node }
        node.children = childNodes
        node.size = total
        node.fileCount = count
        return node
    }

    /// Builds the children of a directory that was left `isUnexpanded` by the depth cap.
    /// Runs off the main actor; the caller attaches the result on the main actor.
    static func expandedChildren(
        of node: FileNode,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) async -> [FileNode] {
        let url = node.url
        return await Task.detached(priority: .userInitiated) {
            var built: [FileNode] = []
            for child in DirectoryScanner.children(of: url) {
                if let sub = scanSync(child, depth: 1, isCancelled: isCancelled) {
                    built.append(sub)
                }
            }
            return compactChildren(built, under: url)
        }.value
    }

    private static func compactChildren(_ children: [FileNode], under parentURL: URL) -> [FileNode] {
        let directories = children.filter(\.isDirectory)
        let files = children.filter { !$0.isDirectory && !$0.isAggregate }
        guard files.count > maxVisibleFilesPerDirectory else {
            return children.sorted { $0.size > $1.size }
        }

        let sortedFiles = files.sorted { $0.size > $1.size }
        let kept = Array(sortedFiles.prefix(maxVisibleFilesPerDirectory))
        let omitted = sortedFiles.dropFirst(maxVisibleFilesPerDirectory)
        let summary = FileNode(
            url: parentURL.appendingPathComponent(".mewp-aggregate-\(UUID().uuidString)"),
            isDirectory: false,
            name: "Other smaller files",
            isAggregate: true
        )
        summary.size = omitted.reduce(0) { $0 + $1.size }
        summary.fileCount = omitted.reduce(0) { $0 + $1.fileCount }

        return (directories + kept + [summary]).sorted { $0.size > $1.size }
    }
}
