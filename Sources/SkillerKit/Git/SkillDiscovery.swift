import Foundation

/// Finds the skill directories inside a checked-out repository.
///
/// Registries disagree about what identifies a skill: skills.sh reports a bare directory name
/// (`swiftui-expert-skill`) with no path, GitHub code search reports a full path
/// (`skills/swiftui/SKILL.md`). Both are resolved against what is actually on disk.
public enum SkillDiscovery {
    /// Directories never worth walking into when looking for skills.
    static let ignoredDirectories: Set<String> = [
        ".git", ".github", "node_modules", ".build", ".swiftpm", "vendor", "dist", "build",
        ".venv", "__pycache__", ".next", "target",
    ]

    public struct ResolutionError: Error, CustomStringConvertible {
        public var identifier: String?
        public var candidates: [String]
        public var repoSlug: String

        public var description: String {
            guard let identifier else {
                return candidates.isEmpty
                    ? "No \(SkillManifest.fileName) found in \(repoSlug)."
                    : """
                      \(repoSlug) contains \(candidates.count) skills. Pick one:
                      \(candidates.map { "  \(repoSlug)/\($0)" }.joined(separator: "\n"))
                      """
            }
            if candidates.isEmpty {
                return "No skill '\(identifier)' in \(repoSlug) — the repository has no \(SkillManifest.fileName)."
            }
            return """
                No skill '\(identifier)' in \(repoSlug). Available:
                \(candidates.map { "  \(repoSlug)/\($0)" }.joined(separator: "\n"))
                """
        }
    }

    /// Resolves an identifier that already names the skill's directory, without walking the
    /// repository.
    ///
    /// Worth having because walking is not cheap on an aggregator: the community registry's own
    /// repository holds over 200 000 `SKILL.md` files, and `discoverSkills` reads and parses the
    /// front matter of every one of them. When the identifier is a path — which is what GitHub
    /// code search reports — one `stat` answers the same question.
    ///
    /// Returns `nil` whenever the identifier does not name a skill directory outright, leaving
    /// the caller to fall back to the full walk and its fuzzier matching.
    public static func skill(at identifier: String, in repositoryDirectory: URL) -> DiscoveredSkill? {
        let relativePath = identifier.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard !relativePath.isEmpty else { return nil }
        // No escaping the clone, and no absolute paths pretending to be identifiers.
        let components = relativePath.split(separator: "/").map(String.init)
        guard !components.contains(".."), !components.contains(".") else { return nil }

        let directory = repositoryDirectory
            .standardizedFileURL
            .appending(path: relativePath, directoryHint: .isDirectory)
        guard Workspace.isDirectory(directory) else { return nil }

        let manifestURL = directory.appending(path: SkillManifest.fileName, directoryHint: .notDirectory)
        guard FileManager.default.fileExists(atPath: manifestURL.path(percentEncoded: false)) else {
            return nil
        }

        return DiscoveredSkill(
            relativePath: relativePath,
            manifest: FrontmatterParser.parse(
                fileAt: manifestURL,
                fallbackName: components.last ?? relativePath
            )
        )
    }

    /// Every directory in `repositoryDirectory` that holds a `SKILL.md`, sorted by path.
    public static func discoverSkills(in repositoryDirectory: URL) -> [DiscoveredSkill] {
        var found: [DiscoveredSkill] = []
        let fileManager = FileManager.default

        let root = repositoryDirectory.standardizedFileURL
        // Absolute URLs on purpose: `relativePath(from:to:)` compares full path components,
        // and `.producesRelativePathURLs` would leave it comparing a relative URL against an
        // absolute one, yielding a path full of `..`.
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }

        for case let url as URL in enumerator {
            let url = url.standardizedFileURL
            let name = url.lastPathComponent

            if ignoredDirectories.contains(name), Workspace.isDirectory(url) {
                enumerator.skipDescendants()
                continue
            }
            guard name.caseInsensitiveCompare(SkillManifest.fileName) == .orderedSame else { continue }

            let skillDirectory = url.deletingLastPathComponent().standardizedFileURL
            let relativePath = LinkManager.relativePath(from: root, to: skillDirectory)
            // A path that escapes the repository means the enumerator handed us something
            // outside the tree; skip rather than build a broken link.
            guard !relativePath.hasPrefix("..") else { continue }
            let normalized = (relativePath == ".") ? "" : relativePath
            let fallbackName = normalized.isEmpty
                ? root.lastPathComponent
                : (normalized.split(separator: "/").last.map(String.init) ?? normalized)

            found.append(
                DiscoveredSkill(
                    relativePath: normalized,
                    manifest: FrontmatterParser.parse(fileAt: url, fallbackName: fallbackName)
                )
            )
        }

        return found.sorted { $0.relativePath < $1.relativePath }
    }

    /// Maps a registry-supplied identifier onto a discovered skill.
    ///
    /// - `identifier == nil` succeeds only when the repository holds exactly one skill;
    ///   otherwise the caller is told to pick.
    /// - Matching tries the full relative path first, then the bare directory name, each
    ///   case-sensitively before case-insensitively.
    public static func resolve(
        identifier: String?,
        in skills: [DiscoveredSkill],
        repoSlug: String
    ) throws -> DiscoveredSkill {
        let candidates = skills.map { $0.relativePath.isEmpty ? "." : $0.relativePath }

        guard let identifier, !identifier.isEmpty else {
            if skills.count == 1 { return skills[0] }
            throw ResolutionError(identifier: nil, candidates: candidates, repoSlug: repoSlug)
        }

        let needle = identifier.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        if let exact = skills.first(where: { $0.relativePath == needle }) { return exact }
        if let byName = uniqueMatch(skills, where: { $0.directoryName == needle }) { return byName }
        if let exactInsensitive = skills.first(where: {
            $0.relativePath.caseInsensitiveCompare(needle) == .orderedSame
        }) { return exactInsensitive }
        if let byNameInsensitive = uniqueMatch(skills, where: {
            $0.directoryName.caseInsensitiveCompare(needle) == .orderedSame
        }) { return byNameInsensitive }
        // A root-level SKILL.md is often referenced by the repository name.
        if let root = skills.first(where: { $0.relativePath.isEmpty }), skills.count == 1 { return root }

        throw ResolutionError(identifier: identifier, candidates: candidates, repoSlug: repoSlug)
    }

    /// Returns the match only when it is unambiguous — two skills with the same directory name
    /// in different subtrees must not silently resolve to whichever came first.
    private static func uniqueMatch(
        _ skills: [DiscoveredSkill],
        where predicate: (DiscoveredSkill) -> Bool
    ) -> DiscoveredSkill? {
        let matches = skills.filter(predicate)
        return matches.count == 1 ? matches[0] : nil
    }
}
