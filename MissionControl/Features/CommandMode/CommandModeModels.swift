import Foundation

struct CommandApplication: Identifiable, Equatable, Hashable {
    let name: String
    let url: URL
    let bundleIdentifier: String?

    var id: String { url.standardizedFileURL.path }
}

enum CommandRoute: Equatable {
    case showFeature(OverlayFeature)
    case openURL(URL)
    case openPath(URL)
    case openApplication(CommandApplication)
    case openNotionCalendar
    case searchFiles(query: String, openFirst: Bool)
    case codex(prompt: String, projectPath: String?)
}

struct CommandResolution: Identifiable, Equatable {
    let id: UUID
    let title: String
    let subtitle: String
    let symbolName: String
    let route: CommandRoute

    init(
        id: UUID = UUID(),
        title: String,
        subtitle: String,
        symbolName: String,
        route: CommandRoute
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.symbolName = symbolName
        self.route = route
    }
}

struct CommandChoice: Identifiable, Equatable {
    let id: UUID
    let title: String
    let subtitle: String
    let symbolName: String
    let resolution: CommandResolution

    init(
        id: UUID = UUID(),
        title: String,
        subtitle: String,
        symbolName: String,
        resolution: CommandResolution
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.symbolName = symbolName
        self.resolution = resolution
    }
}

enum CommandExecutionState: Equatable {
    case idle
    case working(String)
    case succeeded(String)
    case failed(String)
}

enum CommandVoiceTranscriptNormalizer {
    private static let replacementOptions: String.CompareOptions = [
        .regularExpression,
        .caseInsensitive,
    ]

    static func normalize(_ rawTranscript: String) -> String {
        var value = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return value }

        value = value.replacingOccurrences(
            of: "\\b(kodaks?|code\\s+ex)\\b",
            with: "Codex",
            options: replacementOptions
        )
        value = value.replacingOccurrences(
            of: "\\bin\\s+drop\\s+e\\b",
            with: "in Droppy",
            options: replacementOptions
        )
        value = value.replacingOccurrences(
            of: "\\bin\\s+entropy\\b",
            with: "in Droppy",
            options: replacementOptions
        )

        let lower = value.lowercased()
        let commandVerbs = [
            "build", "check", "create", "find", "fix", "inspect", "make",
            "open", "review", "run", "search", "show", "test",
        ]
        if
            lower.range(
                of: "^entropy[[:punct:]]?\\s+(build|check|create|find|fix|inspect|make|open|review|run|search|show|test)\\b",
                options: .regularExpression
            ) != nil
        {
            value = value.replacingOccurrences(
                of: "^entropy\\b",
                with: "in Droppy",
                options: replacementOptions
            )
        } else if
            lower.range(of: "\\bentropy[[:punct:]]?$", options: .regularExpression) != nil,
            commandVerbs.contains(where: { lower.contains("\($0) ") })
        {
            value = value.replacingOccurrences(
                of: "\\bentropy[[:punct:]]?$",
                with: "in Droppy",
                options: replacementOptions
            )
        }

        return value
    }

    static func isRunnable(_ transcript: String) -> Bool {
        let words = transcript
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return false }

        if words.count == 1 {
            return [
                "calendar", "clipboard", "codex", "documents", "downloads",
                "files", "notes", "notion", "shelf", "xcode",
            ].contains(words[0])
        }

        let incompletePhrases: Set<String> = [
            "ask codex", "in droppy", "open the", "search for", "show the",
        ]
        let normalized = words.joined(separator: " ")
        if incompletePhrases.contains(normalized) { return false }

        return ![
            "ask", "build", "create", "find", "fix", "launch", "make",
            "open", "run", "search", "show",
        ].contains(normalized)
    }
}

enum CommandModeResolver {
    static func resolve(
        _ rawQuery: String,
        applications: [CommandApplication],
        notionShortcuts: [NotionShortcut],
        projects: [CodexProjectOption],
        homeURL: URL
    ) -> CommandResolution? {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }

        let normalizedQuery = normalized(query)
        let target = commandTarget(from: normalizedQuery)

        if let feature = feature(for: target) {
            return CommandResolution(
                title: "Show \(feature.title)",
                subtitle: "Silverdeck",
                symbolName: feature.symbolName,
                route: .showFeature(feature)
            )
        }

        if calendarTargets.contains(target) {
            return CommandResolution(
                title: "Open Notion Calendar",
                subtitle: "Local app when installed",
                symbolName: "calendar",
                route: .openNotionCalendar
            )
        }

        if notionHomeTargets.contains(target) {
            return CommandResolution(
                title: "Open Notion",
                subtitle: "Notion home",
                symbolName: "square.grid.2x2",
                route: .openURL(URL(string: "https://www.notion.so")!)
            )
        }

        if let shortcut = notionShortcuts.first(where: {
            normalized($0.title) == target
                || target == "notion \(normalized($0.title))"
        }), let url = URL(string: shortcut.urlString) {
            return CommandResolution(
                title: "Open \(shortcut.title)",
                subtitle: "Notion shortcut",
                symbolName: "link",
                route: .openURL(url)
            )
        }

        if let folder = commonFolder(target: target, homeURL: homeURL) {
            return CommandResolution(
                title: "Open \(folder.lastPathComponent.isEmpty ? "Home" : folder.lastPathComponent)",
                subtitle: folder.path,
                symbolName: "folder",
                route: .openPath(folder)
            )
        }

        if let project = projects.first(where: { projectMatches(target, project: $0) }) {
            let url = URL(fileURLWithPath: project.path, isDirectory: true)
            return CommandResolution(
                title: "Open \(project.name)",
                subtitle: project.path,
                symbolName: "folder.badge.gearshape",
                route: .openPath(url)
            )
        }

        if let application = bestApplicationMatch(target, applications: applications) {
            return CommandResolution(
                title: "Open \(application.name)",
                subtitle: "Application",
                symbolName: "app",
                route: .openApplication(application)
            )
        }

        if let url = webURL(from: target) {
            return CommandResolution(
                title: "Open \(url.host ?? url.absoluteString)",
                subtitle: url.absoluteString,
                symbolName: "safari",
                route: .openURL(url)
            )
        }

        if let fileRequest = fileRequest(from: normalizedQuery) {
            return CommandResolution(
                title: fileRequest.openFirst ? "Open \(fileRequest.query)" : "Find \(fileRequest.query)",
                subtitle: "Search files on this Mac",
                symbolName: "doc.text.magnifyingglass",
                route: .searchFiles(
                    query: fileRequest.query,
                    openFirst: fileRequest.openFirst
                )
            )
        }

        let prompt = strippedCodexPrefix(from: query)
        return CommandResolution(
            title: "Ask Codex",
            subtitle: inferredProjectName(for: prompt, projects: projects)
                .map { "Work in \($0)" }
                ?? "Choose a project if needed",
            symbolName: "sparkles",
            route: .codex(
                prompt: prompt,
                projectPath: inferredProjectPath(for: prompt, projects: projects)
            )
        )
    }

    static func inferredProjectPath(
        for prompt: String,
        projects: [CodexProjectOption]
    ) -> String? {
        inferredProject(for: prompt, projects: projects)?.path
    }

    static func defaultSuggestions(
        applications: [CommandApplication],
        notionShortcuts: [NotionShortcut],
        projects: [CodexProjectOption],
        homeURL: URL
    ) -> [CommandResolution] {
        let queries = [
            "Open Notion Calendar",
            "Open Downloads",
            "Open Xcode",
            "Show Files",
        ]
        return queries.compactMap {
            resolve(
                $0,
                applications: applications,
                notionShortcuts: notionShortcuts,
                projects: projects,
                homeURL: homeURL
            )
        }
    }

    private static let calendarTargets: Set<String> = [
        "calendar", "notion calendar", "the calendar", "my calendar",
    ]

    private static let notionHomeTargets: Set<String> = [
        "notion", "notion home", "notion workspace",
    ]

    private static func feature(for target: String) -> OverlayFeature? {
        let mapping: [String: OverlayFeature] = [
            "silverdeck": .clipboard,
            "emberdeck": .clipboard,
            "mission control": .clipboard,
            "clipboard": .clipboard,
            "clipboard history": .clipboard,
            "shelf": .shelf,
            "codex": .codex,
            "codex tasks": .codex,
            "notion connector": .notion,
            "files": .files,
            "file finder": .files,
            "my files": .files,
            "notes": .notes,
            "my notes": .notes,
        ]
        return mapping[target]
    }

    private static func commonFolder(target: String, homeURL: URL) -> URL? {
        switch target {
        case "home", "home folder", "my home folder":
            return homeURL
        case "downloads", "downloads folder", "my downloads":
            return homeURL.appendingPathComponent("Downloads", isDirectory: true)
        case "documents", "documents folder", "my documents":
            return homeURL.appendingPathComponent("Documents", isDirectory: true)
        case "desktop", "desktop folder", "my desktop":
            return homeURL.appendingPathComponent("Desktop", isDirectory: true)
        case "applications", "applications folder", "apps folder":
            return URL(fileURLWithPath: "/Applications", isDirectory: true)
        default:
            return nil
        }
    }

    private static func projectMatches(_ target: String, project: CodexProjectOption) -> Bool {
        let names = [
            normalized(project.name),
            normalized(URL(fileURLWithPath: project.path).lastPathComponent),
        ]
        return names.contains(target)
            || names.contains(where: { target == "\($0) project" })
    }

    private static func inferredProject(
        for prompt: String,
        projects: [CodexProjectOption]
    ) -> CodexProjectOption? {
        let normalizedPrompt = normalizedWords(prompt)
        return projects.first { project in
            let name = normalizedWords(project.name)
            let folder = normalizedWords(URL(fileURLWithPath: project.path).lastPathComponent)
            return containsWordSequence(name, in: normalizedPrompt)
                || containsWordSequence(folder, in: normalizedPrompt)
                || (
                    name == "droppy"
                        && ["silverdeck", "emberdeck", "mission control"].contains {
                            normalizedPrompt.contains($0)
                        }
                )
        }
    }

    private static func inferredProjectName(
        for prompt: String,
        projects: [CodexProjectOption]
    ) -> String? {
        inferredProject(for: prompt, projects: projects)?.name
    }

    private static func bestApplicationMatch(
        _ target: String,
        applications: [CommandApplication]
    ) -> CommandApplication? {
        let targetWithoutApp = target.hasSuffix(" app")
            ? String(target.dropLast(4))
            : target
        let exact = applications.filter {
            normalized($0.name) == targetWithoutApp
        }
        if exact.count == 1 { return exact[0] }

        let partial = applications.filter {
            normalized($0.name).contains(targetWithoutApp)
        }
        return partial.count == 1 ? partial[0] : nil
    }

    private static func webURL(from target: String) -> URL? {
        let candidate: String
        if target.hasPrefix("http://") || target.hasPrefix("https://") {
            candidate = target
        } else if !target.contains(" "), target.contains(".") {
            candidate = "https://\(target)"
        } else {
            return nil
        }

        guard let url = URL(string: candidate), url.host?.isEmpty == false else {
            return nil
        }
        return url
    }

    private static func fileRequest(from query: String) -> (query: String, openFirst: Bool)? {
        var query = query
        for prefix in ["please ", "can you ", "could you ", "would you "]
            where query.hasPrefix(prefix)
        {
            query = String(query.dropFirst(prefix.count))
            break
        }
        let prefixes: [(String, Bool)] = [
            ("open ", true),
            ("pull up ", true),
            ("find ", false),
            ("search for ", false),
            ("look for ", false),
        ]
        for (prefix, openFirst) in prefixes where query.hasPrefix(prefix) {
            var target = String(query.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            target = stripLeadingArticle(target)
            if target.hasPrefix("latest ") {
                target = String(target.dropFirst("latest ".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard !target.isEmpty else { return nil }
            return (target, openFirst)
        }
        return nil
    }

    private static func commandTarget(from query: String) -> String {
        let prefixes = [
            "please ", "can you ", "could you ", "would you ",
        ]
        var value = query
        for prefix in prefixes where value.hasPrefix(prefix) {
            value = String(value.dropFirst(prefix.count))
            break
        }
        let actionPrefixes = [
            "pull up ", "take me to ", "open ", "launch ", "show ", "go to ",
        ]
        for prefix in actionPrefixes where value.hasPrefix(prefix) {
            value = String(value.dropFirst(prefix.count))
            break
        }
        return stripLeadingArticle(value)
    }

    private static func strippedCodexPrefix(from query: String) -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        for prefix in ["ask codex to", "ask codex", "codex"] {
            guard lower.hasPrefix(prefix), lower.count > prefix.count else { continue }
            let boundaryIndex = lower.index(lower.startIndex, offsetBy: prefix.count)
            let boundary = lower[boundaryIndex]
            guard boundary.isWhitespace || boundary.isPunctuation else { continue }
            let remainder = String(trimmed.dropFirst(prefix.count))
                .trimmingCharacters(
                    in: .whitespacesAndNewlines.union(.punctuationCharacters)
                )
            if !remainder.isEmpty { return remainder }
        }
        return trimmed
    }

    private static func stripLeadingArticle(_ value: String) -> String {
        for prefix in ["the ", "my "] where value.hasPrefix(prefix) {
            return String(value.dropFirst(prefix.count))
        }
        return value
    }

    private static func containsWordSequence(_ needle: String, in value: String) -> Bool {
        value == needle
            || value.hasPrefix("\(needle) ")
            || value.hasSuffix(" \(needle)")
            || value.contains(" \(needle) ")
    }

    private static func normalized(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private static func normalizedWords(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
