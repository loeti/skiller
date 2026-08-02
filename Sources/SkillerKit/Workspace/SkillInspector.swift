import Foundation

/// Everything worth knowing about one skill, whether it is installed or merely named.
public struct SkillDetails: Sendable {
    public struct Entry: Sendable, Hashable {
        public var name: String
        public var isDirectory: Bool
        /// Number of files inside, for directories.
        public var fileCount: Int
    }

    public var name: String
    /// Present when the skill is installed and tracked.
    public var locked: LockedSkill?
    /// Read from the installed `SKILL.md`.
    public var manifest: SkillManifest?
    /// Where `installs/<name>` resolves to, workspace-relative.
    public var resolvedPath: String?
    public var groups: [String]
    public var contents: [Entry]
    /// Registry metadata — the only source of a licence.
    public var registry: RegistryRecord?
    /// Set when the skill is not installed; the reference it would be installed from.
    public var candidateRef: SkillRef?

    public var isInstalled: Bool { locked != nil || resolvedPath != nil }

    /// Prefers the installed manifest's own words over the registry's summary.
    public var description: String? {
        if let description = manifest?.description, !description.isEmpty { return description }
        if let description = registry?.description, !description.isEmpty { return description }
        return nil
    }

    public var license: String? {
        if let license = manifest?.license, !license.isEmpty { return license }
        if let license = registry?.license, !license.isEmpty { return license }
        return nil
    }
}

/// Assembles a `SkillDetails` from the workspace, the skill's own `SKILL.md`, and — when
/// available — the local registry index.
public struct SkillInspector: Sendable {
    private let workspace: Workspace
    private let registry: RegistryShardIndex

    public init(workspace: Workspace, registry: RegistryShardIndex = RegistryShardIndex()) {
        self.workspace = workspace
        self.registry = registry
    }

    public enum InspectionError: Error, CustomStringConvertible {
        case notFound(String)

        public var description: String {
            switch self {
            case .notFound(let argument):
                """
                '\(argument)' is neither installed nor a skill reference.
                Try `skiller list`, or pass owner/repo/skill-id.
                """
            }
        }
    }

    /// `argument` is either an installed name or a skill reference.
    public func inspect(_ argument: String) throws -> SkillDetails {
        if let installed = installedDetails(for: argument) { return installed }

        // Not installed — fall back to treating it as a reference we could install.
        guard let ref = try? SkillRef(parsing: argument) else {
            throw InspectionError.notFound(argument)
        }
        let name = ref.defaultInstallName
        let record = registry.lookup(repo: ref.repoSlug, skillName: name)
        guard record != nil || ref.skillID != nil else {
            throw InspectionError.notFound(argument)
        }

        return SkillDetails(
            name: name,
            groups: [],
            contents: [],
            registry: record,
            candidateRef: ref
        )
    }

    private func installedDetails(for name: String) -> SkillDetails? {
        let installLink = workspace.layout.installLink(name: name)
        let locked = workspace.lock[name]
        guard locked != nil || FileManager.default.fileExists(
            atPath: LinkManager.filesystemPath(installLink)
        ) else { return nil }

        // Resolve through the symlink so the reported path is the real content location.
        let resolved = installLink.resolvingSymlinksInPath()
        let manifestURL = resolved.appending(path: SkillManifest.fileName, directoryHint: .notDirectory)
        let manifest = FileManager.default.fileExists(atPath: manifestURL.path(percentEncoded: false))
            ? FrontmatterParser.parse(fileAt: manifestURL, fallbackName: name)
            : nil

        var record: RegistryRecord?
        if let locked, locked.origin == .git {
            record = registry.lookup(repo: locked.repoSlug, skillName: name)
        }

        return SkillDetails(
            name: name,
            locked: locked,
            manifest: manifest,
            resolvedPath: LinkManager.relativePath(from: workspace.root, to: resolved),
            groups: workspace.groupsContaining(name: name),
            contents: contents(of: resolved),
            registry: record,
            candidateRef: nil
        )
    }

    /// Top-level entries of the skill directory, with a file count per subdirectory — enough
    /// to see what a skill ships without printing a full tree.
    private func contents(of directory: URL) -> [SkillDetails.Entry] {
        let fileManager = FileManager.default
        let children = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return children
            .map { url in
                let isDirectory = Workspace.isDirectory(url)
                return SkillDetails.Entry(
                    name: url.lastPathComponent,
                    isDirectory: isDirectory,
                    fileCount: isDirectory ? Self.countFiles(in: url) : 0
                )
            }
            .sorted { lhs, rhs in
                // Files before directories, so SKILL.md leads.
                if lhs.isDirectory != rhs.isDirectory { return !lhs.isDirectory }
                return lhs.name < rhs.name
            }
    }

    private static func countFiles(in directory: URL) -> Int {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var count = 0
        for case let url as URL in enumerator where !Workspace.isDirectory(url) {
            count += 1
        }
        return count
    }
}
