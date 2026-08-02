import Foundation

/// One leaf skill reached by walking a group tree.
public struct ResolvedSkill: Sendable, Hashable {
    /// The name the skill is deployed under — the directory name of its install.
    public var name: String
    /// `installs/<name>`, the deduplication key.
    ///
    /// Deliberately the install *link* rather than the clone behind it: a project link
    /// therefore keeps pointing at the right content after `sync --update` moves the install
    /// to a new commit.
    public var installPath: URL
    /// The group this skill was first reached through, for reporting.
    public var sourceGroup: String

    public init(name: String, installPath: URL, sourceGroup: String) {
        self.name = name
        self.installPath = installPath
        self.sourceGroup = sourceGroup
    }
}

/// Flattens a group tree under `skills/` down to the leaf skills it references.
///
/// A group holds two kinds of symlink: leaf links into `installs/`, and group links into
/// another group. Nesting is also expressed by plain subdirectories, so both forms are walked.
/// Nothing here writes to disk.
public enum GroupResolver {
    public struct Resolution: Sendable {
        /// Deduplicated by `installPath`, sorted by name.
        public var skills: [ResolvedSkill] = []
        /// Group paths where traversal turned back, as `ios → swift → ios`.
        public var cycles: [String] = []
        /// Workspace-relative paths of links that resolve to nothing.
        public var deadLinks: [String] = []
        /// `name: kept <source> over <source>` — two different targets wanting one name.
        public var collisions: [String] = []
        /// Real skill directories sitting under `skills/`, which `apply` cannot deploy.
        public var unadopted: [String] = []

        public var hasProblems: Bool {
            !cycles.isEmpty || !deadLinks.isEmpty || !collisions.isEmpty || !unadopted.isEmpty
        }
    }

    public struct UnknownGroupError: Error, CustomStringConvertible {
        public var group: String
        public var available: [String]

        public var description: String {
            guard !available.isEmpty else {
                return "No group '\(group)' — this workspace has no groups yet."
            }
            return """
                No group '\(group)'. Available:
                \(available.map { "  \($0)" }.joined(separator: "\n"))
                """
        }
    }

    /// Walks `groups` and every group they link to.
    ///
    /// Requested groups are processed in the order given, directory entries in sorted order, so
    /// "first one wins" on a name collision is a stable answer rather than filesystem luck.
    public static func resolve(groups: [String], in workspace: Workspace) throws -> Resolution {
        let skillsRoot = workspace.layout.skillsDirectory
        let installsRoot = workspace.layout.installsDirectory

        var resolution = Resolution()
        /// Keyed by install path: two groups referencing one skill deploy one link.
        var byInstallPath: [String: ResolvedSkill] = [:]
        /// Keyed by deployed name, to catch two *different* targets wanting the same name.
        var byName: [String: ResolvedSkill] = [:]
        var visited: Set<String> = []

        for requested in groups {
            let normalized = normalize(requested)
            let directory = workspace.layout.groupDirectory(normalized)
            guard Workspace.isDirectory(directory) else {
                throw UnknownGroupError(group: requested, available: workspace.groups())
            }
            walk(
                group: normalized,
                stack: [],
                skillsRoot: skillsRoot,
                installsRoot: installsRoot,
                workspace: workspace,
                visited: &visited,
                byInstallPath: &byInstallPath,
                byName: &byName,
                resolution: &resolution
            )
        }

        resolution.skills = byInstallPath.values.sorted { $0.name < $1.name }
        return resolution
    }

    // MARK: - Traversal

    private static func walk(
        group: String,
        stack: [String],
        skillsRoot: URL,
        installsRoot: URL,
        workspace: Workspace,
        visited: inout Set<String>,
        byInstallPath: inout [String: ResolvedSkill],
        byName: inout [String: ResolvedSkill],
        resolution: inout Resolution
    ) {
        // The cycle check has to come before the visited check: a back edge into a group we
        // already walked is exactly what a cycle looks like, and skipping it silently would
        // hide the very thing worth reporting.
        if stack.contains(group) {
            resolution.cycles.append((stack + [group]).joined(separator: " → "))
            return
        }
        guard visited.insert(group).inserted else { return }

        let directory = workspace.layout.groupDirectory(group)
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ))?.sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []

        for entry in entries {
            // Built from what we walked rather than from the URL FileManager returned, which
            // may have a different — resolved — spelling of the same prefix.
            let entryPath = "\(Layout.skillsDirectoryName)/\(group)/\(entry.lastPathComponent)"

            if LinkManager.isSymlink(entry) {
                guard let destination = LinkManager.resolvedDestination(of: entry),
                      FileManager.default.fileExists(atPath: destination.path(percentEncoded: false))
                else {
                    resolution.deadLinks.append(entryPath)
                    continue
                }
                guard Workspace.isDirectory(destination) else {
                    // A link to a file is not a skill and not a group.
                    resolution.deadLinks.append(entryPath)
                    continue
                }

                if let subgroup = pathUnder(destination, root: skillsRoot) {
                    walk(
                        group: subgroup,
                        stack: stack + [group],
                        skillsRoot: skillsRoot,
                        installsRoot: installsRoot,
                        workspace: workspace,
                        visited: &visited,
                        byInstallPath: &byInstallPath,
                        byName: &byName,
                        resolution: &resolution
                    )
                } else {
                    record(
                        ResolvedSkill(
                            name: destination.lastPathComponent,
                            installPath: destination,
                            sourceGroup: group
                        ),
                        byInstallPath: &byInstallPath,
                        byName: &byName,
                        resolution: &resolution
                    )
                }
                continue
            }

            guard Workspace.isDirectory(entry) else { continue }

            // A real directory under skills/ is a nested group — unless it holds a SKILL.md,
            // in which case it is a skill someone copied in by hand. Deploying that would
            // hand the project a path outside installs/, so it is reported instead.
            let manifest = entry.appending(path: SkillManifest.fileName, directoryHint: .notDirectory)
            if FileManager.default.fileExists(atPath: manifest.path(percentEncoded: false)) {
                resolution.unadopted.append(entryPath)
                continue
            }

            walk(
                group: "\(group)/\(entry.lastPathComponent)",
                stack: stack + [group],
                skillsRoot: skillsRoot,
                installsRoot: installsRoot,
                workspace: workspace,
                visited: &visited,
                byInstallPath: &byInstallPath,
                byName: &byName,
                resolution: &resolution
            )
        }
    }

    /// Adds a leaf, folding duplicates together.
    ///
    /// Two names can only collide when a link points somewhere other than `installs/`, since
    /// that directory is flat and its names are therefore unique by construction. It still has
    /// to be handled: links under `skills/` are the user's to make, and a hand-made one can
    /// point anywhere.
    private static func record(
        _ skill: ResolvedSkill,
        byInstallPath: inout [String: ResolvedSkill],
        byName: inout [String: ResolvedSkill],
        resolution: inout Resolution
    ) {
        let key = skill.installPath.path(percentEncoded: false)
        // Same skill through a second group: keep the first, which names the group that
        // introduced it.
        guard byInstallPath[key] == nil else { return }

        if let clashing = byName[skill.name] {
            resolution.collisions.append(
                "\(skill.name): kept \(clashing.installPath.path(percentEncoded: false)) "
                    + "(via \(clashing.sourceGroup)), dropped "
                    + "\(skill.installPath.path(percentEncoded: false)) (via \(skill.sourceGroup))"
            )
            return
        }

        byInstallPath[key] = skill
        byName[skill.name] = skill
    }

    // MARK: - Helpers

    /// Whether `url` sits inside `root`.
    public static func isUnder(_ url: URL, root: URL) -> Bool {
        pathUnder(url, root: root) != nil
    }

    /// `url` expressed relative to `root`, or `nil` when it is not inside it.
    ///
    /// Both sides are resolved first — see `LinkManager.samePath` for why a lexical comparison
    /// is not enough here. Resolving the *destination* is safe because the answer only decides
    /// whether this is a subgroup; the unresolved path is what gets recorded.
    static func pathUnder(_ url: URL, root: URL) -> String? {
        let relative = LinkManager.relativePath(
            from: root.resolvingSymlinksInPath().standardizedFileURL,
            to: url.resolvingSymlinksInPath().standardizedFileURL
        )
        guard relative != ".", relative != "..", !relative.hasPrefix("../") else { return nil }
        return relative
    }

    /// Trims the slashes a shell tab-completion leaves behind, so `ios/` and `ios` are one group.
    static func normalize(_ group: String) -> String {
        group.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
    }
}
