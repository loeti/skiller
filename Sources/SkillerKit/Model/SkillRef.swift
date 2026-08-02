import Foundation

/// A reference to a skill (or to every skill in a repository).
///
/// Accepted textual forms:
/// - `owner/repo`                              — every skill in the repository
/// - `owner/repo/skill-id`                     — one skill; the identifier may be a nested
///                                               path such as `skills/swiftui`
/// - `owner/repo@main`, `owner/repo/skill@v2`  — with an explicit git ref
/// - `https://github.com/owner/repo`
/// - `https://github.com/owner/repo/tree/main/skills/swiftui`
/// - `git@github.com:owner/repo.git`
public struct SkillRef: Sendable, Hashable, Codable {
    public var host: String
    public var owner: String
    public var repo: String
    /// `nil` means "every skill in the repository".
    public var skillID: String?
    /// Branch, tag or commit. `nil` means the repository's default branch.
    public var gitRef: String?

    public init(host: String = "github.com", owner: String, repo: String, skillID: String? = nil, gitRef: String? = nil) {
        self.host = host
        self.owner = owner
        self.repo = repo
        self.skillID = skillID
        self.gitRef = gitRef
    }

    /// `owner/repo` — identifies the clone, independent of which skill is wanted.
    public var repoSlug: String { "\(owner)/\(repo)" }

    /// Stable identity used for deduplication and display: `owner/repo[/skill-id]`.
    public var canonical: String {
        if let skillID { return "\(repoSlug)/\(skillID)" }
        return repoSlug
    }

    /// The last path component of the skill identifier — the default install name.
    public var defaultInstallName: String {
        guard let skillID, !skillID.isEmpty else { return repo }
        return skillID.split(separator: "/").last.map(String.init) ?? repo
    }

    public var cloneURL: URL? {
        URL(string: "https://\(host)/\(owner)/\(repo).git")
    }
}

extension SkillRef: CustomStringConvertible {
    public var description: String {
        gitRef.map { "\(canonical)@\($0)" } ?? canonical
    }
}

// MARK: - Parsing

extension SkillRef {
    public enum ParseError: Error, CustomStringConvertible, Equatable {
        case empty
        case notEnoughComponents(String)
        case unsupportedHost(String)

        public var description: String {
            switch self {
            case .empty:
                "Empty skill reference."
            case .notEnoughComponents(let input):
                "'\(input)' is not a valid skill reference. Expected 'owner/repo' or 'owner/repo/skill-id'."
            case .unsupportedHost(let host):
                "Host '\(host)' is not supported. Only github.com works today."
            }
        }
    }

    public init(parsing input: String) throws {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ParseError.empty }

        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            try self.init(parsingWebURL: trimmed)
        } else if trimmed.contains("@") && trimmed.contains(":") && !trimmed.hasPrefix("http") {
            try self.init(parsingSCPStyle: trimmed)
        } else {
            try self.init(parsingSlug: trimmed)
        }
    }

    /// `owner/repo[/skill/path][@ref]`
    private init(parsingSlug input: String) throws {
        var body = input
        var ref: String?
        // Only split on the last '@' so that a ref containing '@' still round-trips.
        if let atIndex = body.lastIndex(of: "@"), atIndex != body.startIndex {
            ref = String(body[body.index(after: atIndex)...])
            body = String(body[..<atIndex])
        }

        let components = body.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard components.count >= 2 else { throw ParseError.notEnoughComponents(input) }

        let skill = components.count > 2 ? components[2...].joined(separator: "/") : nil
        self.init(
            owner: components[0],
            repo: Self.strippingGitSuffix(components[1]),
            skillID: skill,
            gitRef: ref?.isEmpty == true ? nil : ref
        )
    }

    /// `https://github.com/owner/repo[/tree/<ref>/<skill path>]`
    private init(parsingWebURL input: String) throws {
        guard let url = URL(string: input), let host = url.host() else {
            throw ParseError.notEnoughComponents(input)
        }
        let normalizedHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        guard normalizedHost == "github.com" else { throw ParseError.unsupportedHost(normalizedHost) }

        var components = url.pathComponents.filter { $0 != "/" }
        guard components.count >= 2 else { throw ParseError.notEnoughComponents(input) }

        let owner = components.removeFirst()
        let repo = Self.strippingGitSuffix(components.removeFirst())

        var gitRef: String?
        var skillID: String?
        // /tree/<ref>/<path...> and /blob/<ref>/<path...> both appear in the wild.
        if let marker = components.first, marker == "tree" || marker == "blob" {
            components.removeFirst()
            if !components.isEmpty { gitRef = components.removeFirst() }
            if !components.isEmpty {
                // A link may point at the SKILL.md itself; the skill is its directory.
                if components.last?.caseInsensitiveCompare(SkillManifest.fileName) == .orderedSame {
                    components.removeLast()
                }
                skillID = components.isEmpty ? nil : components.joined(separator: "/")
            }
        }

        self.init(host: normalizedHost, owner: owner, repo: repo, skillID: skillID, gitRef: gitRef)
    }

    /// `git@github.com:owner/repo.git`
    private init(parsingSCPStyle input: String) throws {
        guard let colonIndex = input.firstIndex(of: ":") else {
            throw ParseError.notEnoughComponents(input)
        }
        let hostPart = String(input[..<colonIndex])
        let pathPart = String(input[input.index(after: colonIndex)...])
        let host = hostPart.split(separator: "@").last.map(String.init) ?? hostPart
        guard host == "github.com" else { throw ParseError.unsupportedHost(host) }

        let components = pathPart.split(separator: "/").map(String.init)
        guard components.count >= 2 else { throw ParseError.notEnoughComponents(input) }
        self.init(
            host: host,
            owner: components[0],
            repo: Self.strippingGitSuffix(components[1]),
            skillID: components.count > 2 ? components[2...].joined(separator: "/") : nil
        )
    }

    private static func strippingGitSuffix(_ name: String) -> String {
        name.hasSuffix(".git") ? String(name.dropLast(4)) : name
    }
}
