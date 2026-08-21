import Foundation

/// A node in a scanned directory tree. Reference type so a big tree can be built
/// bottom-up and re-rooted cheaply by the Space Lens UI. `size` is aggregate
/// allocated bytes (a directory's size is the sum of its subtree).
final class FileNode: Identifiable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let isAggregate: Bool
    var size: Int64 = 0
    var fileCount: Int = 0
    var children: [FileNode] = []
    weak var parent: FileNode?
    /// A directory whose size was measured but whose children were not built, because it
    /// sat past the scan's depth budget. Drilling into it fills the children in on demand.
    /// Building every level eagerly is what made a whole-home scan retain gigabytes.
    var isUnexpanded = false

    /// The URL is already unique within a scan. Avoid allocating a UUID for
    /// every file in a whole-home tree, which can contain hundreds of thousands
    /// of nodes.
    var id: URL { url }

    init(
        url: URL,
        isDirectory: Bool,
        name: String? = nil,
        isAggregate: Bool = false
    ) {
        self.url = url
        self.name = name ?? (url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent)
        self.isDirectory = isDirectory
        self.isAggregate = isAggregate
    }

    /// Fraction of the parent this node occupies (0…1); 1 for the root.
    func fraction(of total: Int64) -> Double {
        guard total > 0 else { return 0 }
        return Double(size) / Double(total)
    }

    /// Depth-first collection of file leaves at/under this node.
    func collectFiles(into out: inout [FileNode]) {
        if isAggregate { return }
        if !isDirectory { out.append(self); return }
        for child in children { child.collectFiles(into: &out) }
    }
}
