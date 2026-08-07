import Foundation
import Testing

@testable import SkillerKit

@Suite("Resolving a skill by path, and progress reporting")
struct InstallProgressTests {
    /// A stand-in repository: skill directories with a `SKILL.md`, no git involved.
    private func makeRepository(paths: [String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "skiller-repo-\(UUID().uuidString)", directoryHint: .isDirectory)
        for path in paths {
            let directory = root.appending(path: path, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try "---\nname: \(directory.lastPathComponent)\ndescription: d\n---\n".write(
                to: directory.appending(path: SkillManifest.fileName, directoryHint: .notDirectory),
                atomically: true,
                encoding: .utf8
            )
        }
        return root
    }

    // MARK: - The path fast path

    @Test("an identifier that names the directory resolves without a scan")
    func resolvesByPath() throws {
        let repo = try makeRepository(paths: ["skills/data/quarkus-developer", "other/skill"])
        defer { try? FileManager.default.removeItem(at: repo) }

        let found = try #require(
            SkillDiscovery.skill(at: "skills/data/quarkus-developer", in: repo)
        )
        #expect(found.relativePath == "skills/data/quarkus-developer")
        #expect(found.directoryName == "quarkus-developer")
        // The front matter is read for the one skill, not for every skill in the repository.
        #expect(found.manifest.name == "quarkus-developer")
    }

    @Test("surrounding slashes do not stop a path from resolving")
    func toleratesSlashes() throws {
        let repo = try makeRepository(paths: ["skills/swiftui"])
        defer { try? FileManager.default.removeItem(at: repo) }
        #expect(SkillDiscovery.skill(at: "/skills/swiftui/", in: repo)?.relativePath == "skills/swiftui")
    }

    @Test("anything that is not a skill directory falls through to the scan")
    func fallsThroughWhenNotAPath() throws {
        let repo = try makeRepository(paths: ["skills/data/quarkus-developer"])
        defer { try? FileManager.default.removeItem(at: repo) }

        // A bare directory name is not a path; matching it is the scan's job.
        #expect(SkillDiscovery.skill(at: "quarkus-developer", in: repo) == nil)
        // A directory without a SKILL.md is not a skill.
        #expect(SkillDiscovery.skill(at: "skills", in: repo) == nil)
        #expect(SkillDiscovery.skill(at: "does/not/exist", in: repo) == nil)
        #expect(SkillDiscovery.skill(at: "", in: repo) == nil)
    }

    @Test("an identifier cannot escape the clone")
    func refusesTraversal() throws {
        let repo = try makeRepository(paths: ["skill"])
        defer { try? FileManager.default.removeItem(at: repo) }
        // The sibling exists, but reaching it through the identifier must not work.
        let sibling = repo.deletingLastPathComponent()
            .appending(path: "escaped-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        try "---\nname: escaped\n---\n".write(
            to: sibling.appending(path: SkillManifest.fileName, directoryHint: .notDirectory),
            atomically: true,
            encoding: .utf8
        )
        defer { try? FileManager.default.removeItem(at: sibling) }

        #expect(SkillDiscovery.skill(at: "../\(sibling.lastPathComponent)", in: repo) == nil)
        #expect(SkillDiscovery.skill(at: "./skill", in: repo) == nil)
    }

    @Test("the fast path and the scan agree on what they find")
    func agreesWithTheScan() throws {
        let repo = try makeRepository(paths: ["a/one", "b/two"])
        defer { try? FileManager.default.removeItem(at: repo) }

        let scanned = SkillDiscovery.discoverSkills(in: repo)
        for skill in scanned {
            let direct = try #require(SkillDiscovery.skill(at: skill.relativePath, in: repo))
            #expect(direct == skill)
        }
    }

    // MARK: - Progress line splitting

    @Test("git progress separated by carriage returns arrives line by line")
    func splitsCarriageReturns() {
        var pending = ""
        var lines: [String] = []
        // What `git clone --progress` actually writes: one line, overwritten repeatedly.
        ProcessRunner.splitProgress(
            "Receiving objects:  1% (1/100)\rReceiving objects: 50% (50/100)\r",
            pending: &pending
        ) { lines.append($0) }

        #expect(lines == ["Receiving objects:  1% (1/100)", "Receiving objects: 50% (50/100)"])
        #expect(pending.isEmpty)
    }

    @Test("a half-written line waits for its terminator instead of being emitted twice")
    func holdsBackPartialLines() {
        var pending = ""
        var lines: [String] = []
        let emit: (String) -> Void = { lines.append($0) }

        ProcessRunner.splitProgress("Receiving objects: 12", pending: &pending, emit)
        #expect(lines.isEmpty)

        ProcessRunner.splitProgress("% (12/100)\r", pending: &pending, emit)
        #expect(lines == ["Receiving objects: 12% (12/100)"])
    }

    // MARK: - Licence lookup

    @Test("a lookup filters on the skill name, not just the repository")
    func lookupIsSelective() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "skiller-index-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let cache = RegistryIndexCache(directory: directory)
        // An aggregator: many skills, one repository slug. Filtering on the slug alone would
        // decode every one of these rows.
        var records = (0..<500).map { index in
            RegistryRecord(
                name: "filler-\(index)", repo: "agg/registry", path: "skills/filler-\(index)",
                branch: "main", stars: 1, license: "MIT", distribution: "permissive",
                category: "", description: "filler"
            )
        }
        records.append(
            RegistryRecord(
                name: "quarkus-developer", repo: "agg/registry", path: "skills/data/quarkus-developer",
                branch: "main", stars: 9, license: "Apache-2.0", distribution: "permissive",
                category: "backend", description: "quarkus"
            )
        )
        try cache.write(records)

        let index = RegistryShardIndex(cache: cache)
        let found = try #require(index.lookup(repo: "agg/registry", skillName: "quarkus-developer"))
        #expect(found.license == "Apache-2.0")
        #expect(found.path == "skills/data/quarkus-developer")

        // A skill the repository does not have stays unfound rather than matching a filler row.
        #expect(index.lookup(repo: "agg/registry", skillName: "not-there") == nil)
        // And the repository still has to match.
        #expect(index.lookup(repo: "other/repo", skillName: "quarkus-developer") == nil)
    }
}
