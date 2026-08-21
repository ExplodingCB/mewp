import Foundation

enum StartupItemScope: String, Sendable {
    case userAgent = "User Agent"
    case systemAgent = "System Agent"
    case systemDaemon = "System Daemon"
}

struct StartupItem: Identifiable, Sendable {
    var plistURL: URL
    var label: String
    var program: String?
    var runAtLoad: Bool
    var keepAlive = false
    var ownerName: String? = nil
    var ownerApplicationURL: URL? = nil
    var scope: StartupItemScope
    var isLoaded: Bool
    var isEnabled: Bool
    var isBroken: Bool

    var id: URL { plistURL }

    var startsAutomatically: Bool { runAtLoad || keepAlive }
    var isAppleItem: Bool { label.hasPrefix("com.apple.") }
    var isReviewCandidate: Bool {
        !isAppleItem && isEnabled && (isBroken || startsAutomatically)
    }

    var startupBehavior: String {
        if isBroken { return "Broken" }
        if keepAlive { return "Persistent" }
        if runAtLoad { return "At login" }
        return "On demand"
    }
}

enum StartupItemScanner {
    static func scan() -> [StartupItem] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let userLoaded = loadedLabels(in: "gui/\(getuid())")
        let systemLoaded = loadedLabels(in: "system")
        let userDisabled = disabledLabels(in: "gui/\(getuid())")
        let systemDisabled = disabledLabels(in: "system")
        let roots: [(URL, StartupItemScope)] = [
            (home.appendingPathComponent("Library/LaunchAgents"), .userAgent),
            (URL(fileURLWithPath: "/Library/LaunchAgents"), .systemAgent),
            (URL(fileURLWithPath: "/Library/LaunchDaemons"), .systemDaemon),
        ]

        return roots.flatMap { root, scope in
            let plists = (try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            return plists
                .filter { $0.pathExtension.caseInsensitiveCompare("plist") == .orderedSame }
                .compactMap {
                    parse(
                        $0,
                        scope: scope,
                        loadedLabels: scope == .systemDaemon ? systemLoaded : userLoaded,
                        disabledLabels: scope == .systemDaemon ? systemDisabled : userDisabled
                    )
                }
        }
        .sorted {
            if $0.isBroken != $1.isBroken { return $0.isBroken }
            return $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
        }
    }

    static func parse(
        _ url: URL,
        scope: StartupItemScope,
        loadedLabels: Set<String>? = nil,
        disabledLabels: Set<String> = []
    ) -> StartupItem? {
        guard
            let data = try? Data(contentsOf: url),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
            let dictionary = plist as? [String: Any]
        else { return nil }

        let label = (dictionary["Label"] as? String) ?? url.deletingPathExtension().lastPathComponent
        let arguments = dictionary["ProgramArguments"] as? [String]
        let rawProgram = (dictionary["Program"] as? String)
            ?? (dictionary["BundleProgram"] as? String)
            ?? arguments?.first
        let program = rawProgram.map(expandHome)
        let ownerApplicationURL = program.flatMap(applicationBundleURL)
        let ownerName = ownerApplicationURL
            .flatMap { Bundle(url: $0) }
            .flatMap {
                ($0.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? ($0.object(forInfoDictionaryKey: "CFBundleName") as? String)
            }
            ?? program.flatMap(commandOwner)
        let keepAliveValue = dictionary["KeepAlive"]
        let keepAlive = (keepAliveValue as? Bool)
            ?? (keepAliveValue is [String: Any])
        let isBroken = program.map {
            $0.hasPrefix("/") && !FileManager.default.fileExists(atPath: $0)
        } ?? true

        return StartupItem(
            plistURL: url,
            label: label,
            program: program,
            runAtLoad: dictionary["RunAtLoad"] as? Bool ?? false,
            keepAlive: keepAlive,
            ownerName: ownerName,
            ownerApplicationURL: ownerApplicationURL,
            scope: scope,
            isLoaded: loadedLabels?.contains(label) ?? loaded(label: label, scope: scope),
            isEnabled: !disabledLabels.contains(label),
            isBroken: isBroken
        )
    }

    private static func expandHome(_ path: String) -> String {
        NSString(string: path).expandingTildeInPath
    }

    static func applicationURL(forProgram path: String) -> URL? {
        applicationBundleURL(path)
    }

    private static func applicationBundleURL(_ path: String) -> URL? {
        SustainedProcessAnalyzer.applicationURL(forExecutablePath: path)
    }

    private static func commandOwner(_ path: String) -> String? {
        if path.hasPrefix("/opt/homebrew/") || path.hasPrefix("/usr/local/Homebrew/") {
            return "Homebrew"
        }
        if path.hasPrefix("/opt/local/") {
            return "MacPorts"
        }
        return nil
    }

    private static func loaded(label: String, scope: StartupItemScope) -> Bool {
        let domain: String
        switch scope {
        case .systemDaemon:
            domain = "system"
        case .userAgent, .systemAgent:
            domain = "gui/\(getuid())"
        }

        return SystemCommand.status("/bin/launchctl", arguments: ["print", "\(domain)/\(label)"]) == 0
    }

    /// Reads each launchd domain once instead of spawning one launchctl process
    /// per plist. Service lines have the form "pid status label".
    private static func loadedLabels(in domain: String) -> Set<String> {
        let result = SystemCommand.run("/bin/launchctl", arguments: ["print", domain])
        guard result.status == 0 else { return [] }
        let text = result.stdout

        var labels = Set<String>()
        var insideServices = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "services = {" {
                insideServices = true
                continue
            }
            if insideServices && trimmed == "}" { break }
            guard insideServices else { continue }
            let fields = trimmed.split(whereSeparator: \.isWhitespace)
            guard
                fields.count >= 3,
                Int(fields[0]) != nil,
                let label = fields.last
            else { continue }
            labels.insert(String(label))
        }
        return labels
    }

    private static func disabledLabels(in domain: String) -> Set<String> {
        let output = SystemCommand.run("/bin/launchctl", arguments: ["print-disabled", domain])
        guard output.status == 0 else { return [] }
        var labels = Set<String>()
        for line in output.stdout.split(separator: "\n") where line.contains("=> true") {
            guard let firstQuote = line.firstIndex(of: "\""),
                  let secondQuote = line[line.index(after: firstQuote)...].firstIndex(of: "\"")
            else { continue }
            labels.insert(String(line[line.index(after: firstQuote)..<secondQuote]))
        }
        return labels
    }
}

enum StartupItemController {
    static func setEnabled(_ enabled: Bool, item: StartupItem) -> MaintenanceResult {
        guard !item.isAppleItem else {
            return MaintenanceResult(
                succeeded: false,
                message: "Apple launch items cannot be changed by CleanMyMewp."
            )
        }
        guard isValid(item) else {
            return MaintenanceResult(succeeded: false, message: "The launch item path or label is not safe.")
        }

        let domain = item.scope == .systemDaemon ? "system" : "gui/\(getuid())"
        let target = "\(domain)/\(item.label)"
        let action = enabled ? "enable" : "disable"

        if item.scope == .userAgent {
            let state = SystemCommand.run("/bin/launchctl", arguments: [action, target])
            guard state.status == 0 else {
                return MaintenanceResult(succeeded: false, message: state.stderr.nonEmpty ?? "launchctl failed.")
            }
            if enabled {
                _ = SystemCommand.run("/bin/launchctl", arguments: ["bootstrap", domain, item.plistURL.path])
            } else {
                _ = SystemCommand.run("/bin/launchctl", arguments: ["bootout", domain, item.plistURL.path])
            }
            return MaintenanceResult(
                succeeded: true,
                message: enabled ? "The launch item is enabled." : "The launch item is disabled."
            )
        }

        let quotedTarget = shellQuote(target)
        let quotedDomain = shellQuote(domain)
        let quotedPath = shellQuote(item.plistURL.path)
        let command: String
        if enabled {
            command = "/bin/launchctl enable \(quotedTarget); /bin/launchctl bootstrap \(quotedDomain) \(quotedPath) || true"
        } else {
            command = "/bin/launchctl disable \(quotedTarget); /bin/launchctl bootout \(quotedDomain) \(quotedPath) || true"
        }
        return MaintenanceRunner.runAdministratorCommand(
            command,
            successMessage: enabled ? "The launch item is enabled." : "The launch item is disabled."
        )
    }

    private static func isValid(_ item: StartupItem) -> Bool {
        let allowedLabel = item.label.range(
            of: #"^[A-Za-z0-9._-]+$"#,
            options: .regularExpression
        ) != nil
        guard allowedLabel else { return false }

        let path = item.plistURL.standardizedFileURL.path
        let expectedRoot: String
        switch item.scope {
        case .userAgent:
            expectedRoot = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/LaunchAgents").path
        case .systemAgent:
            expectedRoot = "/Library/LaunchAgents"
        case .systemDaemon:
            expectedRoot = "/Library/LaunchDaemons"
        }
        return path.hasPrefix(expectedRoot + "/") && item.plistURL.pathExtension == "plist"
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
