import Foundation

/// Everything needed to rebuild the workspace from scratch.
public struct LockFile: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var version: Int
    /// Always sorted by `name` so the file diffs cleanly.
    public var skills: [LockedSkill]

    public init(version: Int = LockFile.currentVersion, skills: [LockedSkill] = []) {
        self.version = version
        self.skills = skills.sorted { $0.name < $1.name }
    }

    public subscript(name: String) -> LockedSkill? {
        skills.first { $0.name == name }
    }

    public mutating func upsert(_ skill: LockedSkill) {
        skills.removeAll { $0.name == skill.name }
        skills.append(skill)
        skills.sort { $0.name < $1.name }
    }

    @discardableResult
    public mutating func remove(name: String) -> LockedSkill? {
        guard let index = skills.firstIndex(where: { $0.name == name }) else { return nil }
        return skills.remove(at: index)
    }

    /// Repositories still referenced by at least one skill.
    public var referencedRepos: Set<String> {
        Set(skills.filter { $0.origin == .git }.map { "\($0.host)/\($0.owner)/\($0.repo)" })
    }
}

/// Which of the three places a recorded licence value came from.
public enum LicenseSource: String, Codable, Sendable {
    /// The `license:` field in the skill's own `SKILL.md`. Most specific.
    case manifest
    /// The community registry's classification of the containing repository.
    case registry
    /// A licence file in the clone. Only its presence is recorded, never a guessed SPDX id.
    case repositoryFile
}

/// Where a skill's content came from.
public enum SkillOrigin: String, Codable, Sendable {
    /// Cloned from a repository into `downloads/`; `installs/<name>` is a symlink into it.
    case git
    /// Adopted from a directory the user already had; `installs/<name>` *is* the content.
    case local
}

public struct LockedSkill: Codable, Sendable, Equatable {
    /// Directory name under `installs/`. Unique across the workspace.
    public var name: String
    public var origin: SkillOrigin
    public var host: String
    public var owner: String
    public var repo: String
    /// Path of the skill directory relative to the repository root.
    public var skillPath: String
    /// The ref that was requested, if any. `nil` means default branch.
    public var gitRef: String?
    /// The commit the clone was resolved to.
    public var commit: String
    /// Group directories under `skills/` linking to this skill.
    public var groups: [String]
    public var installedAt: Date

    /// Resolved licence, and where the value came from. Recorded at install time so an audit
    /// does not have to re-clone or re-query anything.
    public var license: String?
    public var licenseSource: LicenseSource?
    /// The registry's own classification, e.g. `permissive` / `restricted`.
    public var distribution: String?
    /// Name of the licence file found in the clone, as evidence. No SPDX guessing.
    public var licenseFile: String?

    public init(
        name: String,
        origin: SkillOrigin = .git,
        host: String = "",
        owner: String = "",
        repo: String = "",
        skillPath: String = "",
        gitRef: String? = nil,
        commit: String = "",
        groups: [String] = [],
        installedAt: Date = Date(),
        license: String? = nil,
        licenseSource: LicenseSource? = nil,
        distribution: String? = nil,
        licenseFile: String? = nil
    ) {
        self.name = name
        self.origin = origin
        self.host = host
        self.owner = owner
        self.repo = repo
        self.skillPath = skillPath
        self.gitRef = gitRef
        self.commit = commit
        self.groups = groups.sorted()
        self.installedAt = installedAt
        self.license = license
        self.licenseSource = licenseSource
        self.distribution = distribution
        self.licenseFile = licenseFile
    }

    /// An adopted skill has no upstream, so `origin` is written explicitly but tolerated as
    /// absent when reading a lock file written before the field existed.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        origin = try container.decodeIfPresent(SkillOrigin.self, forKey: .origin) ?? .git
        host = try container.decodeIfPresent(String.self, forKey: .host) ?? ""
        owner = try container.decodeIfPresent(String.self, forKey: .owner) ?? ""
        repo = try container.decodeIfPresent(String.self, forKey: .repo) ?? ""
        skillPath = try container.decodeIfPresent(String.self, forKey: .skillPath) ?? ""
        gitRef = try container.decodeIfPresent(String.self, forKey: .gitRef)
        commit = try container.decodeIfPresent(String.self, forKey: .commit) ?? ""
        groups = try container.decodeIfPresent([String].self, forKey: .groups) ?? []
        installedAt = try container.decodeIfPresent(Date.self, forKey: .installedAt) ?? Date()
        license = try container.decodeIfPresent(String.self, forKey: .license)
        licenseSource = try container.decodeIfPresent(LicenseSource.self, forKey: .licenseSource)
        distribution = try container.decodeIfPresent(String.self, forKey: .distribution)
        licenseFile = try container.decodeIfPresent(String.self, forKey: .licenseFile)
    }

    /// Whether the licence is unclear enough to warrant a look before shipping anything
    /// derived from this skill.
    public var needsLicenseReview: Bool {
        guard let license, !license.isEmpty else { return true }
        return license == "NOASSERTION" || distribution == "restricted"
    }

    public var ref: SkillRef {
        SkillRef(host: host, owner: owner, repo: repo, skillID: skillPath, gitRef: gitRef)
    }

    public var repoSlug: String {
        origin == .local ? "(local)" : "\(owner)/\(repo)"
    }

    /// How the source is shown in listings: `owner/repo/skill-path`, or `(local)`.
    public var sourceDescription: String {
        guard origin == .git else { return "(local)" }
        return skillPath.isEmpty ? repoSlug : "\(repoSlug)/\(skillPath)"
    }
}

// MARK: - Persistence

extension LockFile {
    public static func read(from url: URL) throws -> LockFile {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            return LockFile()
        }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return LockFile() }
        return try Self.decoder.decode(LockFile.self, from: data)
    }

    public func write(to url: URL) throws {
        let data = try Self.encoder.encode(self)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// Workspace-level settings. Kept deliberately small; everything here has a working default.
public struct WorkspaceConfig: Codable, Sendable, Equatable {
    /// v2 added the community registry as a source.
    public static let currentVersion = 2

    public var version: Int
    /// Registries consulted by `search` when `--source` is not given.
    public var defaultSources: [SkillSearchResult.Origin]
    /// `git clone --depth`. `nil` clones the full history.
    public var cloneDepth: Int?

    public init(
        version: Int = WorkspaceConfig.currentVersion,
        defaultSources: [SkillSearchResult.Origin] = SkillSearchResult.Origin.allCases,
        cloneDepth: Int? = 1
    ) {
        self.version = version
        self.defaultSources = defaultSources
        self.cloneDepth = cloneDepth
    }

    public static func read(from url: URL) throws -> WorkspaceConfig {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            return WorkspaceConfig()
        }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return WorkspaceConfig() }
        return try LockFile.decoder.decode(WorkspaceConfig.self, from: data)
    }

    /// Brings an older config up to the current version.
    ///
    /// A workspace created before a source existed would silently never use it, so a version
    /// bump adopts any sources it does not know yet. Reading stays free of side effects —
    /// `Workspace` decides when to persist the result.
    ///
    /// - Returns: whether anything changed.
    public mutating func migrate() -> Bool {
        guard version < Self.currentVersion else { return false }
        let known = Set(defaultSources)
        defaultSources += SkillSearchResult.Origin.allCases.filter { !known.contains($0) }
        version = Self.currentVersion
        return true
    }

    public func write(to url: URL) throws {
        let data = try LockFile.encoder.encode(self)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }
}
