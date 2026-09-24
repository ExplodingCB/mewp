import Foundation
import AppKit
import CoreServices
import Security

struct InstalledApplication: Identifiable, Sendable {
    var url: URL
    var name: String
    var bundleIdentifier: String?
    var version: String?
    var size: Int64
    var lastUsed: Date?
    var teamIdentifier: String?

    var id: URL { url }
    var canUninstall: Bool {
        bundleIdentifier != Bundle.main.bundleIdentifier
            && !url.standardizedFileURL.path.hasPrefix("/System/")
    }
}

enum LeftoverMatch: String, Sendable, Hashable {
    case exact = "Exact bundle ID"
    case enhanced = "Related identifier"
    case orphaned = "Orphaned bundle ID"
}

struct AppLeftover: Identifiable, Sendable, Hashable {
    var url: URL
    var size: Int64
    var kind: String
    var match: LeftoverMatch = .exact
    var requiresAdministrator = false

    var id: URL { url }
}

enum ApplicationScanner {
    static func installedApplications() async -> [InstalledApplication] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let roots = [
            URL(fileURLWithPath: "/Applications"),
            home.appendingPathComponent("Applications"),
        ]
        let urls = roots.flatMap { root in
            ((try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isApplicationKey],
                options: [.skipsHiddenFiles]
            )) ?? []).filter { $0.pathExtension.caseInsensitiveCompare("app") == .orderedSame }
        }
        return await concurrentMap(urls, limit: 6) { url in
            let bundle = Bundle(url: url)
            return InstalledApplication(
                url: url,
                name: (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? url.deletingPathExtension().lastPathComponent,
                bundleIdentifier: bundle?.bundleIdentifier,
                version: bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                size: DirectoryScanner.measure(url).allocatedBytes,
                lastUsed: spotlightLastUsedDate(for: url),
                teamIdentifier: teamIdentifier(for: url)
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func leftovers(for app: InstalledApplication) async -> [AppLeftover] {
        guard let bundleID = app.bundleIdentifier, isSafeBundleIdentifier(bundleID) else { return [] }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let locations: [(URL, String, Bool)] = [
            (home.appendingPathComponent("Library/Application Support"), "Application support", false),
            (home.appendingPathComponent("Library/Caches"), "Cache", false),
            (home.appendingPathComponent("Library/Preferences"), "Preferences", false),
            (home.appendingPathComponent("Library/Preferences/ByHost"), "Host preferences", false),
            (home.appendingPathComponent("Library/Containers"), "Container", false),
            (home.appendingPathComponent("Library/Group Containers"), "Group container", false),
            (home.appendingPathComponent("Library/HTTPStorages"), "HTTP storage", false),
            (home.appendingPathComponent("Library/WebKit"), "Web data", false),
            (home.appendingPathComponent("Library/Saved Application State"), "Saved state", false),
            (home.appendingPathComponent("Library/LaunchAgents"), "Launch agent", false),
            (URL(fileURLWithPath: "/Library/Application Support"), "System application support", true),
            (URL(fileURLWithPath: "/Library/Caches"), "System cache", true),
            (URL(fileURLWithPath: "/Library/LaunchAgents"), "System launch agent", true),
            (URL(fileURLWithPath: "/Library/LaunchDaemons"), "System launch daemon", true),
            (URL(fileURLWithPath: "/Library/PrivilegedHelperTools"), "Privileged helper", true),
        ]

        var candidates: [(URL, String, LeftoverMatch, Bool)] = []
        for (root, kind, requiresAdministrator) in locations {
            let children = (try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
            for child in children {
                guard let match = matchTier(child.lastPathComponent, bundleID: bundleID) else {
                    continue
                }
                candidates.append((child, kind, match, requiresAdministrator))
            }
        }
        return await concurrentMap(candidates, limit: 6) { candidate in
            AppLeftover(
                url: candidate.0,
                size: DirectoryScanner.measure(candidate.0).allocatedBytes,
                kind: candidate.1,
                match: candidate.2,
                requiresAdministrator: candidate.3
            )
        }
        .sorted { $0.size > $1.size }
    }

    static func matches(_ filename: String, bundleID: String) -> Bool {
        let lower = filename.lowercased()
        let id = bundleID.lowercased()
        return lower == id
            || lower.hasPrefix(id + ".")
            || lower == id + ".plist"
            || lower == id + ".savedstate"
    }

    static func matchTier(_ filename: String, bundleID: String) -> LeftoverMatch? {
        if matches(filename, bundleID: bundleID) { return .exact }
        let components = bundleID.lowercased().split(separator: ".")
        guard components.count >= 3 else { return nil }
        let shortened = components.suffix(2).joined(separator: ".")
        let lower = filename.lowercased()
        if lower == shortened
            || lower == shortened + ".plist"
            || lower == shortened + ".savedstate"
            || lower.hasPrefix(shortened + ".") {
            return .enhanced
        }
        return nil
    }

    static func orphanedLeftovers(
        installedApplications: [InstalledApplication]
    ) async -> [AppLeftover] {
        let installedIDs = Set(
            installedApplications.compactMap { $0.bundleIdentifier?.lowercased() }
        )
        let installedVendorPrefixes = Set(installedIDs.compactMap(vendorPrefix))
        let home = FileManager.default.homeDirectoryForCurrentUser
        let locations: [(URL, String)] = [
            (home.appendingPathComponent("Library/Application Support"), "Application support"),
            (home.appendingPathComponent("Library/Caches"), "Cache"),
            (home.appendingPathComponent("Library/Preferences"), "Preferences"),
            (home.appendingPathComponent("Library/Containers"), "Container"),
            (home.appendingPathComponent("Library/HTTPStorages"), "HTTP storage"),
            (home.appendingPathComponent("Library/WebKit"), "Web data"),
            (home.appendingPathComponent("Library/Saved Application State"), "Saved state"),
            (home.appendingPathComponent("Library/LaunchAgents"), "Launch agent"),
        ]

        var seen = Set<URL>()
        var candidates: [(URL, String)] = []
        for (root, kind) in locations {
            let children = (try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for child in children {
                if kind == "Launch agent",
                   let startupItem = StartupItemScanner.parse(
                       child,
                       scope: .userAgent,
                       loadedLabels: [],
                       disabledLabels: []
                   ),
                   !startupItem.isBroken {
                    continue
                }
                let values = try? child.resourceValues(forKeys: [.isDirectoryKey])
                let isDirectory = values?.isDirectory ?? false
                guard let identifier = bundleIdentifierCandidate(
                    from: child.lastPathComponent,
                    isDirectory: isDirectory
                ) else {
                    continue
                }
                guard !isSystemIdentifier(identifier) else { continue }
                let belongsToInstalledApp = installedIDs.contains {
                    identifier == $0 || identifier.hasPrefix($0 + ".")
                }
                let sharesInstalledVendor = vendorPrefix(identifier).map {
                    installedVendorPrefixes.contains($0)
                } ?? false
                let registeredApplicationExists =
                    NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) != nil
                guard
                    !belongsToInstalledApp,
                    !sharesInstalledVendor,
                    !registeredApplicationExists,
                    seen.insert(child).inserted
                else { continue }
                candidates.append((child, kind))
            }
        }

        return await concurrentMap(candidates, limit: 6) { candidate in
            AppLeftover(
                url: candidate.0,
                size: DirectoryScanner.measure(candidate.0).allocatedBytes,
                kind: candidate.1,
                match: .orphaned
            )
        }
        .filter { $0.size > 0 }
        .sorted { $0.size > $1.size }
    }

    static func uninstall(
        _ app: InstalledApplication,
        leftovers: [AppLeftover]
    ) -> MaintenanceResult {
        guard app.canUninstall else {
            return MaintenanceResult(succeeded: false, message: "Mewp cannot remove itself or a system app.")
        }
        guard FileManager.default.fileExists(atPath: app.url.path) else {
            return MaintenanceResult(succeeded: false, message: "The application is no longer at that location.")
        }

        if let bundleID = app.bundleIdentifier {
            for running in NSWorkspace.shared.runningApplications
                where running.bundleIdentifier == bundleID {
                _ = running.terminate()
            }
        }

        let regularLeftovers = leftovers.filter { !$0.requiresAdministrator }
        let administratorLeftovers = leftovers.filter(\.requiresAdministrator)
        let regularURLs = [app.url] + regularLeftovers.map(\.url)
        let sizes = Dictionary(
            uniqueKeysWithValues: [(app.url, app.size)] + regularLeftovers.map { ($0.url, $0.size) }
        )
        let result = FileActions.trash(regularURLs, sizes: sizes)
        let administratorResult = MaintenanceRunner.trashAdministratorItems(
            administratorLeftovers.map(\.url)
        )
        if result.failed.isEmpty && administratorResult.succeeded {
            return MaintenanceResult(
                succeeded: true,
                message: "Moved \(regularURLs.count + administratorLeftovers.count) item"
                    + "\(regularURLs.count + administratorLeftovers.count == 1 ? "" : "s") to Trash."
            )
        }
        let failureCount = result.failed.count + (administratorResult.succeeded ? 0 : administratorLeftovers.count)
        return MaintenanceResult(
            succeeded: false,
            message: "\(failureCount) item\(failureCount == 1 ? "" : "s") could not be moved to Trash."
        )
    }

    private static func spotlightLastUsedDate(for url: URL) -> Date? {
        guard let item = MDItemCreate(kCFAllocatorDefault, url.path as CFString) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }

    private static func teamIdentifier(for url: URL) -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode
        else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess,
              let dictionary = information as? [String: Any]
        else { return nil }
        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }

    private static func bundleIdentifierCandidate(
        from filename: String,
        isDirectory: Bool
    ) -> String? {
        var value = filename.lowercased()
        if !isDirectory && !value.hasSuffix(".plist") {
            return nil
        }
        for suffix in [".savedstate", ".plist"] where value.hasSuffix(suffix) {
            value.removeLast(suffix.count)
        }
        if let range = value.range(
            of: #"[.-][0-9A-F]{8}-[0-9A-F-]{27,}$"#,
            options: [.regularExpression, .caseInsensitive]
        ) {
            value.removeSubrange(range)
        }
        guard value.split(separator: ".").count >= 3,
              value.range(of: #"^[a-z0-9.-]+$"#, options: .regularExpression) != nil
        else { return nil }
        return value
    }

    private static func vendorPrefix(_ identifier: String) -> String? {
        let components = identifier.lowercased().split(separator: ".")
        guard components.count >= 2 else { return nil }
        return components.prefix(2).joined(separator: ".")
    }

    private static func isSystemIdentifier(_ identifier: String) -> Bool {
        let lower = identifier.lowercased()
        return lower.hasPrefix("com.apple.")
            || lower.contains(".com.apple.")
            || lower.hasPrefix("group.")
            || lower.hasPrefix("systemgroup.")
            || lower.hasPrefix("org.cups.")
            || lower.hasPrefix("org.swift.")
    }

    private static func isSafeBundleIdentifier(_ value: String) -> Bool {
        value.count >= 3
            && value.contains(".")
            && value.range(of: #"^[A-Za-z0-9.-]+$"#, options: .regularExpression) != nil
    }
}
