import Foundation

/// One row of a merged search across registries.
public struct SkillSearchResult: Sendable, Hashable, Identifiable, Codable {
    public enum Origin: String, Sendable, Codable, CaseIterable {
        case skillsSh = "skills.sh"
        case gitHub = "github"
        case registry = "registry"
    }

    public var ref: SkillRef
    public var displayName: String
    public var description: String?
    /// Install count reported by skills.sh.
    public var installs: Int?
    /// Star count of the containing repository.
    public var stars: Int?
    /// SPDX-ish licence string, only the community registry reports one.
    public var license: String?
    /// `permissive` / `restricted` / … — the registry's own classification.
    public var distribution: String?
    public var category: String?
    /// Which registries produced this row. A skill found by several carries all of them.
    public var origins: Set<Origin>

    /// Deduplication key: repository plus the skill's *directory name*, not its full path.
    ///
    /// The sources disagree on how to spell the same skill — skills.sh reports the bare
    /// directory (`swift-concurrency`) while the registry reports where it sits
    /// (`skills/swift-concurrency`). Keying on the full path lists one skill twice. Keying on
    /// the directory name merges them, which matches how installation resolves the skill
    /// anyway: `SkillDiscovery` looks the directory up in the clone and refuses ambiguity.
    public var id: String {
        "\(ref.repoSlug)/\(ref.defaultInstallName)".lowercased()
    }

    public init(
        ref: SkillRef,
        displayName: String,
        description: String? = nil,
        installs: Int? = nil,
        stars: Int? = nil,
        license: String? = nil,
        distribution: String? = nil,
        category: String? = nil,
        origins: Set<Origin>
    ) {
        self.ref = ref
        self.displayName = displayName
        self.description = description
        self.installs = installs
        self.stars = stars
        self.license = license
        self.distribution = distribution
        self.category = category
        self.origins = origins
    }

    /// Combines two rows describing the same skill, keeping the richer value of each field.
    public func merged(with other: SkillSearchResult) -> SkillSearchResult {
        var result = self
        result.origins.formUnion(other.origins)
        result.installs = Self.preferLarger(installs, other.installs)
        result.stars = Self.preferLarger(stars, other.stars)
        if result.description?.isEmpty ?? true { result.description = other.description }
        if result.license?.isEmpty ?? true { result.license = other.license }
        if result.distribution?.isEmpty ?? true { result.distribution = other.distribution }
        if result.category?.isEmpty ?? true { result.category = other.category }
        // Keep the most specific reference: a full path resolves without guessing, a bare
        // directory name needs a lookup, and no skill id at all means the whole repository.
        if Self.specificity(other.ref) > Self.specificity(result.ref) {
            result.ref.skillID = other.ref.skillID
        }
        return result
    }

    private static func specificity(_ ref: SkillRef) -> Int {
        guard let skillID = ref.skillID, !skillID.isEmpty else { return 0 }
        return 1 + skillID.split(separator: "/").count
    }

    private static func preferLarger(_ lhs: Int?, _ rhs: Int?) -> Int? {
        switch (lhs, rhs) {
        case (let l?, let r?): max(l, r)
        case (let l?, nil): l
        case (nil, let r?): r
        case (nil, nil): nil
        }
    }

    /// Rough popularity, used only to break ties between rows with the same fusion score.
    /// Not a ranking signal on its own — see `MergedRegistry.fuse`.
    public var popularity: Int { (installs ?? 0) + (stars ?? 0) }

    /// Short licence marker for listings. `nil` when the source told us nothing.
    public var licenseLabel: String? {
        guard let license, !license.isEmpty else { return nil }
        // The registry writes NOASSERTION when GitHub could not classify the licence file.
        if license == "NOASSERTION" { return "licence?" }
        return license
    }

    /// True when the registry flagged the licence as anything other than freely reusable.
    public var isLicenseRestricted: Bool {
        distribution == "restricted" || license == "NOASSERTION"
    }
}
