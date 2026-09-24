import Foundation

/// The hardcoded "safety database": every place we consider junk, what it is,
/// how risky it is to remove, and what permission it needs. This is the single
/// source of truth the Cleanup scanner walks. Paths that don't exist on a given
/// machine simply yield zero items.
enum SafetyRules {

    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    private static func lib(_ path: String) -> URL {
        home.appendingPathComponent("Library").appendingPathComponent(path)
    }
    private static func dot(_ path: String) -> URL {
        home.appendingPathComponent(path)
    }

    /// All cleanup categories in display order. Root-owned entries are review-only
    /// and use a per-action administrator prompt. Anything that could destroy real
    /// user data is deliberately absent (see `excludedByDesign`).
    static func categories() -> [CleanupCategory] {
        [
            userCaches,
            browserCaches,
            sandboxedAppCaches,
            safariCaches,
            userLogs,
            systemCachesAndLogs,
            savedAppState,
            xcodeJunk,
            devToolCaches,
            oldInstallers,
            trash,
            iosBackups,
            mailAttachments,
        ]
    }

    // MARK: - Safe, no special permission

    static let userCaches = CleanupCategory(
        id: "user-caches",
        name: "User Caches",
        subtitle: "Regenerable app caches in ~/Library/Caches",
        systemImage: "internaldrive",
        risk: .safe,
        permission: .none,
        sources: [
            JunkSource(
                root: lib("Caches"),
                mode: .childrenAsItems,
                strategy: .moveItemToTrash,
                // Clearing these causes re-sync churn or font glitches — leave them.
                skipNames: [
                    "com.apple.FontRegistry",
                    "CloudKit",
                    "com.apple.containermanagerd",
                    "com.apple.Safari",
                    "Google",
                    "Firefox",
                    "Homebrew",
                    "pip",
                    "CocoaPods",
                ]
            )
        ]
    )

    static let browserCaches = CleanupCategory(
        id: "browser-caches",
        name: "Browser Caches",
        subtitle: "Regenerable Chrome and Firefox web caches",
        systemImage: "globe",
        risk: .safe,
        permission: .none,
        sources: [
            JunkSource(
                root: lib("Caches/Google/Chrome"),
                mode: .folderContents,
                strategy: .emptyContentsToTrash,
                requireAppNotRunning: ["com.google.Chrome"]
            ),
            JunkSource(
                root: lib("Caches/Firefox"),
                mode: .folderContents,
                strategy: .emptyContentsToTrash,
                requireAppNotRunning: ["org.mozilla.firefox"]
            ),
            JunkSource(
                root: lib("Application Support/Firefox/Profiles"),
                mode: .childSubfolders(relativePath: "cache2"),
                strategy: .emptyContentsToTrash,
                requireAppNotRunning: ["org.mozilla.firefox"]
            ),
        ]
    )

    static let sandboxedAppCaches = CleanupCategory(
        id: "sandboxed-app-caches",
        name: "Sandboxed App Caches",
        subtitle: "Regenerable caches stored inside app containers",
        systemImage: "shippingbox",
        risk: .safe,
        permission: .fullDiskAccess,
        sources: [
            JunkSource(
                root: lib("Containers"),
                mode: .childSubfolders(relativePath: "Data/Library/Caches"),
                strategy: .emptyContentsToTrash
            ),
        ]
    )

    static let safariCaches = CleanupCategory(
        id: "safari-caches",
        name: "Safari Caches",
        subtitle: "Safari web caches, scanned only while Safari is closed",
        systemImage: "safari",
        risk: .safe,
        permission: .fullDiskAccess,
        sources: [
            JunkSource(
                root: lib("Containers/com.apple.Safari/Data/Library/Caches"),
                mode: .folderContents,
                strategy: .emptyContentsToTrash,
                requireAppNotRunning: ["com.apple.Safari"]
            ),
            JunkSource(
                root: lib("Caches/com.apple.Safari"),
                mode: .folderContents,
                strategy: .emptyContentsToTrash,
                requireAppNotRunning: ["com.apple.Safari"]
            ),
        ]
    )

    static let userLogs = CleanupCategory(
        id: "user-logs",
        name: "User Logs",
        subtitle: "Diagnostic and app logs in ~/Library/Logs",
        systemImage: "doc.text.magnifyingglass",
        risk: .safe,
        permission: .none,
        sources: [
            JunkSource(root: lib("Logs"), mode: .childrenAsItems, strategy: .moveItemToTrash)
        ]
    )

    static let systemCachesAndLogs = CleanupCategory(
        id: "system-caches-logs",
        name: "System Caches & Logs",
        subtitle: "Reviewed root-owned entries in /Library, never selected automatically",
        systemImage: "externaldrive.badge.gearshape",
        risk: .caution,
        permission: .admin,
        sources: [
            JunkSource(
                root: URL(fileURLWithPath: "/Library/Caches"),
                mode: .childrenAsItems,
                strategy: .moveItemToTrash
            ),
            JunkSource(
                root: URL(fileURLWithPath: "/Library/Logs"),
                mode: .childrenAsItems,
                strategy: .moveItemToTrash
            ),
        ]
    )

    static let savedAppState = CleanupCategory(
        id: "saved-app-state",
        name: "Saved Application State",
        subtitle: "Window/session restore data apps recreate on next launch",
        systemImage: "macwindow.on.rectangle",
        risk: .safe,
        permission: .none,
        sources: [
            JunkSource(root: lib("Saved Application State"),
                       mode: .childrenAsItems, strategy: .moveItemToTrash)
        ]
    )

    static let xcodeJunk = CleanupCategory(
        id: "xcode-junk",
        name: "Xcode & Simulator Junk",
        subtitle: "Derived data, device support, simulator caches",
        systemImage: "hammer",
        risk: .safe,
        permission: .none,
        sources: [
            JunkSource(root: lib("Developer/Xcode/DerivedData"),
                       mode: .childrenAsItems, strategy: .moveItemToTrash),
            JunkSource(root: lib("Developer/Xcode/iOS DeviceSupport"),
                       mode: .childrenAsItems, strategy: .moveItemToTrash),
            JunkSource(root: lib("Developer/Xcode/watchOS DeviceSupport"),
                       mode: .childrenAsItems, strategy: .moveItemToTrash),
            JunkSource(root: lib("Developer/Xcode/tvOS DeviceSupport"),
                       mode: .childrenAsItems, strategy: .moveItemToTrash),
            JunkSource(root: lib("Developer/CoreSimulator/Caches"),
                       mode: .folderContents, strategy: .emptyContentsToTrash),
        ]
    )

    static let devToolCaches = CleanupCategory(
        id: "dev-tool-caches",
        name: "Developer Tool Caches",
        subtitle: "npm, cargo, gradle, and Go module download caches",
        systemImage: "terminal",
        risk: .safe,
        permission: .none,
        sources: [
            JunkSource(root: dot(".npm/_cacache"), mode: .folderContents, strategy: .emptyContentsToTrash),
            JunkSource(root: dot(".cargo/registry/cache"), mode: .folderContents, strategy: .emptyContentsToTrash),
            JunkSource(root: dot(".gradle/caches"), mode: .folderContents, strategy: .emptyContentsToTrash),
            JunkSource(root: dot("go/pkg/mod/cache/download"), mode: .folderContents, strategy: .emptyContentsToTrash),
            JunkSource(root: lib("Caches/Homebrew"), mode: .folderContents, strategy: .emptyContentsToTrash),
            JunkSource(root: lib("Caches/pip"), mode: .folderContents, strategy: .emptyContentsToTrash),
            JunkSource(root: lib("Caches/CocoaPods"), mode: .folderContents, strategy: .emptyContentsToTrash),
        ]
    )

    // MARK: - Caution (real files; never pre-selected)

    static let oldInstallers = CleanupCategory(
        id: "old-installers",
        name: "Downloaded Installers",
        subtitle: "Disk images and packages sitting in ~/Downloads",
        systemImage: "opticaldisc",
        risk: .caution,
        permission: .none,
        sources: [
            JunkSource(root: dot("Downloads"),
                       mode: .matchingFiles(extensions: ["dmg", "pkg", "iso"], recursive: false),
                       strategy: .moveItemToTrash)
        ]
    )

    // MARK: - Full Disk Access required

    static let trash = CleanupCategory(
        id: "trash",
        name: "Trash",
        subtitle: "Permanently empty the Trash to reclaim its space",
        systemImage: "trash",
        // Emptying Trash cannot itself be moved to Trash, so this must always
        // be an explicit selection.
        risk: .caution,
        permission: .fullDiskAccess,
        sources: [
            JunkSource(root: home.appendingPathComponent(".Trash"),
                       mode: .folderContents, strategy: .emptyContentsPermanent)
        ] + externalTrashSources
    )

    static let iosBackups = CleanupCategory(
        id: "ios-backups",
        name: "iOS Device Backups",
        subtitle: "Local iPhone/iPad backups — often many gigabytes each",
        systemImage: "iphone",
        risk: .caution,
        permission: .fullDiskAccess,
        sources: [
            JunkSource(root: lib("Application Support/MobileSync/Backup"),
                       mode: .childrenAsItems, strategy: .moveItemToTrash)
        ]
    )

    static let mailAttachments = CleanupCategory(
        id: "mail-attachments",
        name: "Mail Attachment Cache",
        subtitle: "Locally cached attachments (re-downloadable from the server)",
        systemImage: "envelope",
        risk: .caution,
        permission: .fullDiskAccess,
        sources: [
            JunkSource(root: lib("Containers/com.apple.mail/Data/Library/Mail Downloads"),
                       mode: .folderContents, strategy: .emptyContentsToTrash,
                       requireAppNotRunning: ["com.apple.mail"])
        ]
    )

    private static var externalTrashSources: [JunkSource] {
        var sources = [
            JunkSource(
                root: lib("Mobile Documents/com~apple~CloudDocs/.Trash"),
                mode: .folderContents,
                strategy: .emptyContentsPermanent
            ),
        ]
        let volumes = (try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: "/Volumes"),
            includingPropertiesForKeys: [.isVolumeKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        for volume in volumes {
            sources.append(
                JunkSource(
                    root: volume
                        .appendingPathComponent(".Trashes")
                        .appendingPathComponent(String(getuid())),
                    mode: .folderContents,
                    strategy: .emptyContentsPermanent
                )
            )
        }
        return sources
    }

    /// Documented here so the exclusion is intentional and reviewable, never an
    /// accident: these are things some Mac cleaning tools touch that we
    /// refuse to, because the downside outweighs the reclaimed space.
    static let excludedByDesign: [String] = [
        "/System/* — SIP-protected, read-only system volume",
        "/private/var/folders — live per-user temp actively mmap'd by running apps",
        "App bundle .lproj / lipo thinning — breaks code signatures & notarization",
        "~/.m2/repository — may hold locally-built artifacts, not just cache",
        "~/Library/Mail V* MailData — envelope index; corruption risk",
    ]
}
