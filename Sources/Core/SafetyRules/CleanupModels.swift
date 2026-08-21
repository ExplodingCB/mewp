import Foundation

/// How confident we are that removing an item is harmless.
enum RiskLevel: Int, Comparable, Sendable {
    case safe = 0     // regenerable junk; pre-selected by default
    case caution = 1  // usually fine, but user should glance (e.g. iOS backups)
    case risky = 2    // real data loss possible; never pre-selected

    static func < (a: RiskLevel, b: RiskLevel) -> Bool { a.rawValue < b.rawValue }

    var label: String {
        switch self {
        case .safe: return "Safe"
        case .caution: return "Review"
        case .risky: return "Careful"
        }
    }
}

/// What the OS requires before we can even see/delete these paths.
enum PermissionNeed: Sendable {
    case none            // ordinary home-dir paths
    case fullDiskAccess  // TCC-protected (Mail, Safari, Containers, ~/.Trash, MobileSync…)
    case admin           // root-owned; needs a per-action administrator prompt
}

/// How an individual item is removed.
enum DeleteStrategy: Sendable, Equatable {
    case moveItemToTrash        // trash the item itself (reversible)
    case emptyContentsToTrash   // trash each direct child, keep the container folder
    case emptyContentsPermanent // permanently remove each child (used for ~/.Trash)

    var isAlwaysPermanent: Bool {
        self == .emptyContentsPermanent
    }
}

/// How a source directory expands into individual junk items.
enum SourceMode: Sendable {
    /// Each immediate child of `root` becomes its own item (e.g. per-app cache folder).
    case childrenAsItems
    /// `root` itself is a single item whose size is its contents.
    case folderContents
    /// Regular files anywhere under `root` matching these lowercased extensions.
    case matchingFiles(extensions: Set<String>, recursive: Bool)
    /// A named subfolder beneath every immediate child of `root` becomes an
    /// item. Used for sandbox container caches without treating the container
    /// itself as disposable.
    case childSubfolders(relativePath: String)
}

/// One concrete place on disk a category harvests from.
struct JunkSource: Sendable {
    var root: URL
    var mode: SourceMode
    var strategy: DeleteStrategy
    var skipNames: Set<String> = []          // child names never to touch
    var requireAppNotRunning: [String] = []   // bundle ids that must be quit first
}

/// A user-facing grouping of junk (System Caches, Xcode Junk, Trash, …).
struct CleanupCategory: Identifiable, Sendable {
    var id: String
    var name: String
    var subtitle: String
    var systemImage: String
    var risk: RiskLevel
    var permission: PermissionNeed
    var sources: [JunkSource]

    /// Safe categories are pre-checked; everything else is opt-in.
    var selectedByDefault: Bool { risk == .safe }
}

/// A single removable thing discovered by a scan.
struct JunkItem: Identifiable, Sendable {
    let id = UUID()
    var url: URL
    var displayName: String
    var size: Int64
    var isDirectory: Bool
    var strategy: DeleteStrategy
    var categoryID: String
    var requiresAdministrator: Bool = false
}

/// Discovered items for one category, plus scan bookkeeping.
struct CategoryScanResult: Identifiable, Sendable {
    var category: CleanupCategory
    var items: [JunkItem]
    /// True when the category was skipped because its permission wasn't granted.
    var lockedByPermission: Bool = false
    /// Non-nil when a source was skipped for another reason (e.g. app running).
    var note: String? = nil

    var id: String { category.id }
    var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }
    var isEmpty: Bool { items.isEmpty }
}
