import Foundation

/// skills.sh — GitHub-backed registry behind `npx skills`.
///
/// The search endpoint is undocumented but public and needs no credentials:
///
/// ```
/// GET https://www.skills.sh/api/search?q=swiftui
/// { "query": …, "skills": [ { "id": "owner/repo/skill-id", "skillId": …,
///                             "name": …, "installs": 27980, "source": "owner/repo" } ] }
/// ```
///
/// It returns roughly 100 rows and ignores any limit parameter, so trimming happens here.
/// There is no detail endpoint and no description field — descriptions come from the
/// `SKILL.md` front matter once the repository has been cloned.
public struct SkillsShRegistry: SkillRegistry {
    public let origin = SkillSearchResult.Origin.skillsSh
    private let baseURL: URL

    public init(baseURL: URL = URL(string: "https://www.skills.sh")!) {
        self.baseURL = baseURL
    }

    public func search(query: String, limit: Int) async throws -> [SkillSearchResult] {
        var components = URLComponents(url: baseURL.appending(path: "api/search"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = components?.url else {
            throw RegistryError(registry: origin.rawValue, reason: "could not build request URL")
        }

        let response = try await HTTPClient.getJSON(
            SearchResponse.self,
            url: url,
            registryName: origin.rawValue
        )

        return response.skills
            .compactMap(Self.makeResult)
            .prefix(limit)
            .map { $0 }
    }

    static func makeResult(_ entry: SearchResponse.Entry) -> SkillSearchResult? {
        // `source` is "owner/repo"; anything else is a shape we do not understand.
        let parts = entry.source.split(separator: "/").map(String.init)
        guard parts.count == 2 else { return nil }

        let skillID = entry.skillId.trimmingCharacters(in: .whitespacesAndNewlines)
        let ref = SkillRef(
            owner: parts[0],
            repo: parts[1],
            skillID: skillID.isEmpty ? nil : skillID
        )
        return SkillSearchResult(
            ref: ref,
            displayName: entry.name.isEmpty ? (skillID.isEmpty ? parts[1] : skillID) : entry.name,
            installs: entry.installs,
            origins: [.skillsSh]
        )
    }

    struct SearchResponse: Decodable {
        struct Entry: Decodable {
            var id: String
            var skillId: String
            var name: String
            var installs: Int?
            var source: String
        }

        var skills: [Entry]
    }
}
