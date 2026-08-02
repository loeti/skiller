import Foundation
import Testing

@testable import SkillToolKit

@Suite("Registry parsing and fusion")
struct RegistryTests {
    // MARK: - skills.sh

    @Test("a skills.sh row becomes owner/repo/skill-id")
    func mapsSkillsShEntry() throws {
        let entry = SkillsShRegistry.SearchResponse.Entry(
            id: "avdlee/swiftui-agent-skill/swiftui-expert-skill",
            skillId: "swiftui-expert-skill",
            name: "swiftui-expert-skill",
            installs: 27980,
            source: "avdlee/swiftui-agent-skill"
        )
        let result = try #require(SkillsShRegistry.makeResult(entry))
        #expect(result.ref.owner == "avdlee")
        #expect(result.ref.repo == "swiftui-agent-skill")
        #expect(result.ref.skillID == "swiftui-expert-skill")
        #expect(result.installs == 27980)
        #expect(result.origins == [.skillsSh])
    }

    @Test("a malformed source field is dropped rather than guessed at")
    func rejectsMalformedSource() {
        let entry = SkillsShRegistry.SearchResponse.Entry(
            id: "weird", skillId: "x", name: "x", installs: nil, source: "no-slash"
        )
        #expect(SkillsShRegistry.makeResult(entry) == nil)
    }

    @Test("the real response shape decodes")
    func decodesSkillsShPayload() throws {
        let json = """
            {"query":"swift","searchType":"fuzzy","count":2,"duration_ms":12,
             "skills":[
               {"id":"expo/skills/expo-ui-swiftui","skillId":"expo-ui-swiftui",
                "name":"expo ui swiftui","installs":12916,"source":"expo/skills"},
               {"id":"clerk/skills/clerk-swift","skillId":"clerk-swift",
                "name":"clerk-swift","installs":8827,"source":"clerk/skills"}]}
            """
        let response = try JSONDecoder().decode(
            SkillsShRegistry.SearchResponse.self,
            from: Data(json.utf8)
        )
        #expect(response.skills.count == 2)
        #expect(response.skills[0].skillId == "expo-ui-swiftui")
    }

    // MARK: - GitHub

    @Test("a SKILL.md path resolves to its directory")
    func derivesSkillIdentifierFromPath() {
        #expect(GitHubRegistry.skillIdentifier(fromPath: "skills/swiftui/SKILL.md") == "skills/swiftui")
        #expect(GitHubRegistry.skillIdentifier(fromPath: "swiftui/SKILL.md") == "swiftui")
        #expect(GitHubRegistry.skillIdentifier(fromPath: "SKILL.md") == nil)
    }

    @Test("code search hits that are not SKILL.md files are discarded")
    func ignoresContentOnlyMatches() {
        let item = GitHubRegistry.CodeSearchResponse.Item(
            path: "docs/README.md",
            repository: .init(fullName: "owner/repo", description: nil, stargazersCount: 10)
        )
        #expect(GitHubRegistry.makeResult(item) == nil)
    }

    @Test("a code search hit keeps repository metadata")
    func mapsCodeSearchItem() throws {
        let item = GitHubRegistry.CodeSearchResponse.Item(
            path: "skills/swiftui/SKILL.md",
            repository: .init(fullName: "rshankras/apple-skills", description: "Apple skills", stargazersCount: 42)
        )
        let result = try #require(GitHubRegistry.makeResult(item))
        #expect(result.ref.canonical == "rshankras/apple-skills/skills/swiftui")
        #expect(result.displayName == "swiftui")
        #expect(result.stars == 42)
    }

    // MARK: - Fusion

    @Test("a skill found by both registries outranks single-source hits")
    func fusionRewardsAgreement() {
        let shared = SkillRef(owner: "o", repo: "r", skillID: "shared")
        let skillsShOnly = SkillRef(owner: "o", repo: "r", skillID: "popular")

        let listA = [
            SkillSearchResult(ref: skillsShOnly, displayName: "popular", installs: 100_000, origins: [.skillsSh]),
            SkillSearchResult(ref: shared, displayName: "shared", installs: 10, origins: [.skillsSh]),
        ]
        let listB = [
            SkillSearchResult(ref: shared, displayName: "shared", stars: 1, origins: [.gitHub]),
        ]

        let fused = MergedRegistry.fuse([listA, listB], limit: 10)
        #expect(fused.first?.ref.canonical == "o/r/shared")
        #expect(fused.first?.origins == [.skillsSh, .gitHub])
    }

    @Test("install counts do not drown out a registry that reports none")
    func fusionIgnoresRawMagnitude() {
        let listA = (1...5).map { index in
            SkillSearchResult(
                ref: SkillRef(owner: "a", repo: "r", skillID: "s\(index)"),
                displayName: "s\(index)",
                installs: 50_000,
                origins: [.skillsSh]
            )
        }
        let listB = [
            SkillSearchResult(
                ref: SkillRef(owner: "b", repo: "r", skillID: "top"),
                displayName: "top",
                origins: [.gitHub]
            )
        ]

        let fused = MergedRegistry.fuse([listA, listB], limit: 10)
        // The GitHub row is first in its own list, so it must appear near the top despite
        // having no popularity signal at all.
        let position = try? #require(fused.firstIndex { $0.ref.owner == "b" })
        #expect((position ?? .max) <= 1)
    }

    @Test("merging keeps the richer fields from either side")
    func mergesFields() {
        let ref = SkillRef(owner: "o", repo: "r", skillID: "s")
        let left = SkillSearchResult(ref: ref, displayName: "s", installs: 10, origins: [.skillsSh])
        let right = SkillSearchResult(
            ref: ref, displayName: "s", description: "does things", stars: 5, origins: [.gitHub]
        )
        let merged = left.merged(with: right)
        #expect(merged.installs == 10)
        #expect(merged.stars == 5)
        #expect(merged.description == "does things")
        #expect(merged.origins == [.skillsSh, .gitHub])
    }

    @Test("deduplication is case-insensitive on the canonical id")
    func deduplicatesCaseInsensitively() {
        let lower = SkillSearchResult(
            ref: SkillRef(owner: "twostraws", repo: "swiftui-agent-skill", skillID: "swiftui-pro"),
            displayName: "swiftui-pro",
            origins: [.skillsSh]
        )
        let upper = SkillSearchResult(
            ref: SkillRef(owner: "twostraws", repo: "SwiftUI-Agent-Skill", skillID: "swiftui-pro"),
            displayName: "swiftui-pro",
            origins: [.gitHub]
        )
        #expect(MergedRegistry.deduplicate([lower, upper]).count == 1)
    }

    @Test("the same skill spelled with and without its directory prefix is one row")
    func deduplicatesAcrossPathSpellings() {
        // skills.sh reports the bare directory, the registry reports the full path.
        let bare = SkillSearchResult(
            ref: SkillRef(owner: "dpearson2699", repo: "swift-ios-skills", skillID: "swift-concurrency"),
            displayName: "swift-concurrency",
            installs: 3000,
            origins: [.skillsSh]
        )
        let full = SkillSearchResult(
            ref: SkillRef(owner: "dpearson2699", repo: "swift-ios-skills", skillID: "skills/swift-concurrency"),
            displayName: "swift-concurrency",
            description: "Resolve Swift concurrency compiler errors",
            origins: [.registry]
        )

        let merged = MergedRegistry.deduplicate([bare, full])
        #expect(merged.count == 1)
        // The more specific path survives, because it installs without a lookup.
        #expect(merged[0].ref.skillID == "skills/swift-concurrency")
        #expect(merged[0].description == "Resolve Swift concurrency compiler errors")
        #expect(merged[0].installs == 3000)
    }

    // MARK: - Diversity cap

    @Test("one repository cannot take over the result list")
    func capsResultsPerRepository() {
        let hog = (1...10).map { index in
            SkillSearchResult(
                ref: SkillRef(owner: "mirror", repo: "everything", skillID: "s\(index)"),
                displayName: "s\(index)",
                origins: [.gitHub]
            )
        }
        let others = (1...5).map { index in
            SkillSearchResult(
                ref: SkillRef(owner: "author\(index)", repo: "skill", skillID: "s"),
                displayName: "real\(index)",
                origins: [.skillsSh]
            )
        }

        let capped = MergedRegistry.capPerRepository(hog + others, limit: 8, perRepo: 3)
        #expect(capped.count == 8)
        #expect(capped.filter { $0.ref.repoSlug == "mirror/everything" }.count == 3)
        #expect(capped.filter { $0.ref.repoSlug != "mirror/everything" }.count == 5)
    }

    @Test("held-back rows backfill rather than returning a short list")
    func backfillsWhenCorpusIsConcentrated() {
        let all = (1...10).map { index in
            SkillSearchResult(
                ref: SkillRef(owner: "mirror", repo: "everything", skillID: "s\(index)"),
                displayName: "s\(index)",
                origins: [.gitHub]
            )
        }
        // Nothing else to fill with, so the cap must yield rather than starve the user.
        #expect(MergedRegistry.capPerRepository(all, limit: 6, perRepo: 3).count == 6)
    }

    // MARK: - Local registry index

    @Test("all query terms in the name beat one term plus a description hit")
    func rankingPrefersFullNameMatches() {
        let terms = RegistryShardIndex.tokenize("swift concurrency")
        let generic = RegistryRecord(
            name: "swift", repo: "o/r", path: "swift", branch: "main", stars: 0,
            license: "", distribution: "", category: "",
            description: "Swift development: concurrency patterns, async/await, actors."
        )
        let specific = RegistryRecord(
            name: "swift-concurrency-expert", repo: "o/r2", path: "x", branch: "main", stars: 0,
            license: "", distribution: "", category: "", description: "Review Swift 6.2 code."
        )
        #expect(
            RegistryShardIndex.score(specific, terms: terms)
                > RegistryShardIndex.score(generic, terms: terms)
        )
    }

    @Test("an exact name match outranks a partial one")
    func rankingPrefersExactName() {
        let terms = RegistryShardIndex.tokenize("swift concurrency")
        func record(_ name: String) -> RegistryRecord {
            RegistryRecord(
                name: name, repo: "o/r", path: name, branch: "main", stars: 0,
                license: "", distribution: "", category: "", description: ""
            )
        }
        #expect(
            RegistryShardIndex.score(record("swift-concurrency"), terms: terms)
                > RegistryShardIndex.score(record("swift-concurrency-expert"), terms: terms)
        )
    }

    @Test("a record missing any term does not place at all")
    func rankingRequiresEveryTerm() {
        let terms = RegistryShardIndex.tokenize("swift concurrency")
        let unrelated = RegistryRecord(
            name: "swift-format", repo: "o/r", path: "x", branch: "main", stars: 0,
            license: "", distribution: "", category: "", description: "Formatting rules."
        )
        #expect(RegistryShardIndex.score(unrelated, terms: terms) == 0)
    }

    @Test("the byte filter finds terms regardless of case")
    func byteFilterIsCaseInsensitive() {
        let line = Array("Swift-Concurrency\tOwner/Repo".utf8)
        line.withUnsafeBufferPointer { buffer in
            #expect(RegistryShardIndex.containsCaseInsensitive(buffer, Array("concurrency".utf8)))
            #expect(RegistryShardIndex.containsCaseInsensitive(buffer, Array("owner".utf8)))
            #expect(!RegistryShardIndex.containsCaseInsensitive(buffer, Array("swiftui".utf8)))
        }
    }

    @Test("a path pointing at SKILL.md is normalised to its directory")
    func normalisesSkillPath() {
        let normalise = RegistryIndexCache.Shard.Entry.skillDirectory
        #expect(normalise("skills/swiftui/SKILL.md") == "skills/swiftui")
        #expect(normalise("skills/swiftui") == "skills/swiftui")
        #expect(normalise("/skills/swiftui/") == "skills/swiftui")
        #expect(normalise("SKILL.md") == "")
    }

    @Test("malformed field types do not fail the whole shard")
    func toleratesLooseFieldTypes() throws {
        // `description` really does arrive as an array for some upstream records.
        let json = """
            {"skills":[
              {"name":"a","description":["line one","line two"],"repo":"o/r","path":"a","stars":"42"},
              {"name":"b","description":"plain","repo":"o/r","path":"b","stars":7}]}
            """
        let shard = try JSONDecoder().decode(RegistryIndexCache.Shard.self, from: Data(json.utf8))
        #expect(shard.skills.count == 2)
        #expect(shard.skills[0].record.description == "line one line two")
        #expect(shard.skills[0].record.stars == 42)
        #expect(shard.skills[1].record.stars == 7)
    }

    @Test("tabs and newlines in descriptions cannot break the row format")
    func sanitisesRowFields() {
        let messy = "line one\twith tab\nand newline"
        let sanitised = RegistryIndexCache.sanitize(messy)
        #expect(!sanitised.contains("\t"))
        #expect(!sanitised.contains("\n"))
    }

    @Test("an unclear licence is flagged")
    func flagsUnclearLicense() {
        let restricted = SkillSearchResult(
            ref: SkillRef(owner: "o", repo: "r", skillID: "s"),
            displayName: "s",
            license: "NOASSERTION",
            distribution: "restricted",
            origins: [.registry]
        )
        #expect(restricted.isLicenseRestricted)
        #expect(restricted.licenseLabel == "licence?")

        let permissive = SkillSearchResult(
            ref: SkillRef(owner: "o", repo: "r", skillID: "s"),
            displayName: "s",
            license: "MIT",
            distribution: "permissive",
            origins: [.registry]
        )
        #expect(!permissive.isLicenseRestricted)
        #expect(permissive.licenseLabel == "MIT")
    }
}
