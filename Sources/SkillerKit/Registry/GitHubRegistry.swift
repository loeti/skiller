import Foundation

/// GitHub code search, scoped to `SKILL.md` files.
///
/// ```
/// GET /search/code?q=filename:SKILL.md+<query>
/// items[].repository.full_name + items[].path  →  owner/repo + skill directory
/// ```
///
/// Code search requires authentication and allows ~10 requests per minute, so the token
/// comes from `GITHUB_TOKEN`/`GH_TOKEN`/`gh auth token`. Without one this registry reports
/// a warning rather than failing the whole search.
public struct GitHubRegistry: SkillRegistry {
    public let origin = SkillSearchResult.Origin.gitHub
    private let apiBaseURL: URL
    private let tokenProvider: @Sendable () async -> String?

    public init(
        apiBaseURL: URL = URL(string: "https://api.github.com")!,
        tokenProvider: @escaping @Sendable () async -> String? = { await GitHubTokenResolver.shared.token() }
    ) {
        self.apiBaseURL = apiBaseURL
        self.tokenProvider = tokenProvider
    }

    public func search(query: String, limit: Int) async throws -> [SkillSearchResult] {
        guard let token = await tokenProvider() else {
            throw RegistryError(
                registry: origin.rawValue,
                reason: "no token — code search needs one. Set GITHUB_TOKEN or run `gh auth login`."
            )
        }

        var components = URLComponents(
            url: apiBaseURL.appending(path: "search/code"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "q", value: "filename:\(SkillManifest.fileName) \(query)"),
            URLQueryItem(name: "per_page", value: String(min(max(limit, 1), 100))),
        ]
        guard let url = components?.url else {
            throw RegistryError(registry: origin.rawValue, reason: "could not build request URL")
        }

        let response = try await HTTPClient.getJSON(
            CodeSearchResponse.self,
            url: url,
            headers: [
                "Accept": "application/vnd.github+json",
                "X-GitHub-Api-Version": "2022-11-28",
                "Authorization": "Bearer \(token)",
            ],
            registryName: origin.rawValue
        )

        return response.items.compactMap(Self.makeResult)
    }

    static func makeResult(_ item: CodeSearchResponse.Item) -> SkillSearchResult? {
        let parts = item.repository.fullName.split(separator: "/").map(String.init)
        guard parts.count == 2 else { return nil }
        // Only take real SKILL.md hits; code search matches on content too.
        guard item.path.split(separator: "/").last?.caseInsensitiveCompare(SkillManifest.fileName) == .orderedSame
        else { return nil }

        let skillID = skillIdentifier(fromPath: item.path)
        let ref = SkillRef(owner: parts[0], repo: parts[1], skillID: skillID)
        // Deliberately no description: code search only exposes the *repository* blurb, which
        // describes the collection ("Claude Code Skills"), not the skill. Showing it as the
        // skill's description is worse than showing nothing — the registry supplies the real
        // one, and merging prefers whichever source has it.
        return SkillSearchResult(
            ref: ref,
            displayName: skillID.map { $0.split(separator: "/").last.map(String.init) ?? $0 } ?? parts[1],
            stars: item.repository.stargazersCount,
            origins: [.gitHub]
        )
    }

    /// `skills/swiftui/SKILL.md` → `skills/swiftui`; a root-level `SKILL.md` → `nil`.
    static func skillIdentifier(fromPath path: String) -> String? {
        var components = path.split(separator: "/").map(String.init)
        guard !components.isEmpty else { return nil }
        components.removeLast()
        return components.isEmpty ? nil : components.joined(separator: "/")
    }

    struct CodeSearchResponse: Decodable {
        struct Repository: Decodable {
            var fullName: String
            var description: String?
            var stargazersCount: Int?

            enum CodingKeys: String, CodingKey {
                case fullName = "full_name"
                case description
                case stargazersCount = "stargazers_count"
            }
        }

        struct Item: Decodable {
            var path: String
            var repository: Repository
        }

        var items: [Item]
    }
}
