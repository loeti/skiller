import Foundation

/// The YAML front matter of a `SKILL.md` file.
public struct SkillManifest: Sendable, Hashable {
    public static let fileName = "SKILL.md"

    /// The `name:` field, or the directory name when the front matter omits it.
    public var name: String
    public var description: String?
    public var license: String?
    public var version: String?
    /// Every remaining scalar front-matter entry, for display and future use.
    public var extras: [String: String]

    public init(
        name: String,
        description: String? = nil,
        license: String? = nil,
        version: String? = nil,
        extras: [String: String] = [:]
    ) {
        self.name = name
        self.description = description
        self.license = license
        self.version = version
        self.extras = extras
    }
}

/// A skill directory discovered inside a cloned repository.
public struct DiscoveredSkill: Sendable, Hashable {
    /// Path of the skill directory relative to the repository root, e.g. `skills/swiftui`.
    /// An empty string means the repository root itself contains the `SKILL.md`.
    public var relativePath: String
    public var manifest: SkillManifest

    public init(relativePath: String, manifest: SkillManifest) {
        self.relativePath = relativePath
        self.manifest = manifest
    }

    /// The directory name — what skills.sh calls the `skillId`.
    public var directoryName: String {
        relativePath.split(separator: "/").last.map(String.init) ?? relativePath
    }
}
