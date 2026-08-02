import Foundation
import Testing

@testable import SkillerKit

@Suite("SkillRef parsing")
struct SkillRefTests {
    @Test("owner/repo without a skill means the whole repository")
    func parsesRepoSlug() throws {
        let ref = try SkillRef(parsing: "avdlee/swiftui-agent-skill")
        #expect(ref.owner == "avdlee")
        #expect(ref.repo == "swiftui-agent-skill")
        #expect(ref.skillID == nil)
        #expect(ref.gitRef == nil)
        #expect(ref.canonical == "avdlee/swiftui-agent-skill")
    }

    @Test("owner/repo/skill-id pins one skill")
    func parsesSkillSlug() throws {
        let ref = try SkillRef(parsing: "avdlee/swiftui-agent-skill/swiftui-expert-skill")
        #expect(ref.skillID == "swiftui-expert-skill")
        #expect(ref.defaultInstallName == "swiftui-expert-skill")
    }

    @Test("a nested skill path stays intact")
    func parsesNestedSkillPath() throws {
        let ref = try SkillRef(parsing: "rshankras/claude-code-apple-skills/skills/swiftui")
        #expect(ref.skillID == "skills/swiftui")
        #expect(ref.defaultInstallName == "swiftui")
    }

    @Test("a trailing @ref is split off")
    func parsesGitRef() throws {
        let ref = try SkillRef(parsing: "owner/repo/skill@v1.2.0")
        #expect(ref.skillID == "skill")
        #expect(ref.gitRef == "v1.2.0")
        #expect(ref.description == "owner/repo/skill@v1.2.0")
    }

    @Test("https tree URLs carry both ref and path")
    func parsesTreeURL() throws {
        let ref = try SkillRef(parsing: "https://github.com/owner/repo/tree/main/skills/swiftui")
        #expect(ref.owner == "owner")
        #expect(ref.repo == "repo")
        #expect(ref.gitRef == "main")
        #expect(ref.skillID == "skills/swiftui")
    }

    @Test("a link to the SKILL.md itself resolves to its directory")
    func parsesBlobURLToDirectory() throws {
        let ref = try SkillRef(parsing: "https://github.com/owner/repo/blob/main/skills/swiftui/SKILL.md")
        #expect(ref.skillID == "skills/swiftui")
    }

    @Test("the .git suffix is dropped")
    func stripsGitSuffix() throws {
        #expect(try SkillRef(parsing: "https://github.com/owner/repo.git").repo == "repo")
        #expect(try SkillRef(parsing: "git@github.com:owner/repo.git").repo == "repo")
    }

    @Test("a bare name is rejected")
    func rejectsBareName() {
        #expect(throws: SkillRef.ParseError.self) {
            try SkillRef(parsing: "just-a-name")
        }
    }

    @Test("non-GitHub hosts are rejected for now")
    func rejectsOtherHosts() {
        #expect(throws: SkillRef.ParseError.self) {
            try SkillRef(parsing: "https://gitlab.com/owner/repo")
        }
    }

    @Test("clone URL is derived from host, owner and repo")
    func buildsCloneURL() throws {
        let ref = try SkillRef(parsing: "owner/repo/skill")
        #expect(ref.cloneURL?.absoluteString == "https://github.com/owner/repo.git")
    }
}
