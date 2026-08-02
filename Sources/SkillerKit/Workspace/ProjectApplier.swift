import Foundation

/// Materialises a resolved set of skills as flat symlinks in a project's `.claude/skills/`.
///
/// The workspace stays the single copy of every skill; a project only ever gets links into it.
/// Links are absolute, because a project and its workspace are independent trees — see
/// `LinkManager.LinkStyle`.
public struct ProjectApplier: Sendable {
    public static let claudeDirectoryName = ".claude"
    public static let skillsSubdirectory = "skills"
    /// What `apply` adds to `.gitignore`.
    public static let gitignoreEntry = ".claude/"

    public let projectRoot: URL
    /// The workspace directory a link must point into to count as ours.
    public let installsDirectory: URL

    public init(projectRoot: URL, installsDirectory: URL) {
        self.projectRoot = projectRoot.standardizedFileURL
        self.installsDirectory = installsDirectory.standardizedFileURL
    }

    public init(projectRoot: URL, workspace: Workspace) {
        self.init(projectRoot: projectRoot, installsDirectory: workspace.layout.installsDirectory)
    }

    public var claudeDirectory: URL {
        projectRoot.appending(path: Self.claudeDirectoryName, directoryHint: .isDirectory)
    }

    public var skillsDirectory: URL {
        claudeDirectory.appending(path: Self.skillsSubdirectory, directoryHint: .isDirectory)
    }

    public var gitignoreFile: URL {
        projectRoot.appending(path: ".gitignore", directoryHint: .notDirectory)
    }

    // MARK: - Report

    public enum GitignoreOutcome: Sendable, Equatable {
        case appended
        case created
        case alreadyCovered
        /// No `.gitignore`, and nothing suggesting this directory is a git working tree.
        case skippedNoRepository
        case disabled
    }

    public struct Report: Sendable {
        public var created: [String] = []
        public var updated: [String] = []
        public var unchanged: [String] = []
        /// Symlinks `--clean` took out before applying.
        public var removed: [String] = []
        /// Links from an earlier `apply` that these groups no longer contain. Reported rather
        /// than deleted, because a project may well be applying several group sets on purpose.
        public var stale: [String] = []
        /// Names where a real file or directory occupies the link path. Never touched.
        public var blocked: [String] = []
        public var gitignore: GitignoreOutcome = .disabled

        public var madeChanges: Bool {
            !created.isEmpty || !updated.isEmpty || !removed.isEmpty
                || gitignore == .appended || gitignore == .created
        }
    }

    // MARK: - Apply

    /// - Parameter clean: remove every symlink already in `.claude/skills/` first. Real files
    ///   and directories are never removed, with or without this flag — `LinkManager` refuses.
    /// - Parameter dryRun: compute the same report without touching the filesystem.
    public func apply(
        _ skills: [ResolvedSkill],
        clean: Bool = false,
        dryRun: Bool = false,
        updateGitignore: Bool = true
    ) throws -> Report {
        var report = Report()
        let applied = Set(skills.map(\.name))

        // Snapshot before anything changes, so `stale` describes what was there on arrival.
        let existingLinks = LinkManager.symlinks(in: skillsDirectory)

        if clean {
            for link in existingLinks {
                if !dryRun { try LinkManager.removeLink(at: link) }
                // A link that is about to be recreated is not a removal worth reporting; it
                // shows up below as created or unchanged.
                if !applied.contains(link.lastPathComponent) {
                    report.removed.append(link.lastPathComponent)
                }
            }
        }

        if !dryRun {
            try FileManager.default.createDirectory(at: skillsDirectory, withIntermediateDirectories: true)
        }

        // A dry run leaves the links in place, so `--clean` has to be simulated for the report
        // to match what a real run would print.
        let clearedInDryRun: Set<String> = clean && dryRun
            ? Set(existingLinks.map(\.lastPathComponent))
            : []

        for skill in skills {
            let link = skillsDirectory.appending(path: skill.name, directoryHint: .notDirectory)
            var state = LinkManager.state(of: link, expectedTarget: skill.installPath, style: .absolute)
            if clearedInDryRun.contains(skill.name) { state = .missing }

            switch state {
            case .correct:
                report.unchanged.append(skill.name)
                continue
            case .missing:
                report.created.append(skill.name)
            case .wrongTarget, .broken:
                report.updated.append(skill.name)
            case .occupiedByRealPath:
                report.blocked.append(skill.name)
                continue
            }

            if !dryRun {
                try LinkManager.createLink(
                    at: link,
                    to: skill.installPath,
                    replaceExisting: true,
                    style: .absolute
                )
            }
        }

        if !clean {
            for link in existingLinks where !applied.contains(link.lastPathComponent) {
                guard isManaged(link) else { continue }
                report.stale.append(link.lastPathComponent)
            }
        }

        report.gitignore = updateGitignore ? try ensureGitignore(dryRun: dryRun) : .disabled
        return report
    }

    /// Whether a link in `.claude/skills/` was put there by this workspace, i.e. points at one
    /// of its installs. Anything else in that directory belongs to the project and is left alone.
    public func isManaged(_ link: URL) -> Bool {
        guard let destination = LinkManager.resolvedDestination(of: link) else { return false }
        return LinkManager.samePath(destination.deletingLastPathComponent(), installsDirectory)
    }

    // MARK: - .gitignore

    /// Makes sure `.claude/` is ignored.
    ///
    /// The directory holds nothing but links into a machine-local workspace, so committing it
    /// would give every other clone a set of dangling paths.
    func ensureGitignore(dryRun: Bool) throws -> GitignoreOutcome {
        let path = gitignoreFile.path(percentEncoded: false)

        guard FileManager.default.fileExists(atPath: path) else {
            // Creating a .gitignore somewhere that is not a repository would just be litter.
            guard isGitWorkingTree else { return .skippedNoRepository }
            if !dryRun {
                try (Self.gitignoreEntry + "\n").write(to: gitignoreFile, atomically: true, encoding: .utf8)
            }
            return .created
        }

        let contents = (try? String(contentsOf: gitignoreFile, encoding: .utf8)) ?? ""
        guard !Self.ignoresClaudeDirectory(contents) else { return .alreadyCovered }

        if !dryRun {
            // A file not ending in a newline would otherwise get the entry glued onto its last
            // line, silently changing that pattern.
            let separator = contents.isEmpty || contents.hasSuffix("\n") ? "" : "\n"
            try (contents + separator + Self.gitignoreEntry + "\n")
                .write(to: gitignoreFile, atomically: true, encoding: .utf8)
        }
        return .appended
    }

    /// Whether some line already ignores `.claude`, in any of the spellings git accepts.
    static func ignoresClaudeDirectory(_ contents: String) -> Bool {
        for line in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            var pattern = line.trimmingCharacters(in: .whitespaces)
            guard !pattern.isEmpty, !pattern.hasPrefix("#") else { continue }
            // A negation re-includes the path, so it is not a match.
            guard !pattern.hasPrefix("!") else { continue }
            if pattern.hasPrefix("/") { pattern.removeFirst() }
            if pattern.hasSuffix("/") { pattern.removeLast() }
            if pattern == Self.claudeDirectoryName { return true }
        }
        return false
    }

    /// `.git` is a directory in a normal clone and a file in a worktree or submodule.
    var isGitWorkingTree: Bool {
        FileManager.default.fileExists(
            atPath: projectRoot.appending(path: ".git", directoryHint: .notDirectory)
                .path(percentEncoded: false)
        )
    }
}
