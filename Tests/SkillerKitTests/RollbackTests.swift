import Foundation
import Testing

@testable import SkillerKit

@Suite("Rolling a skill back after an update")
struct RollbackTests {
    /// An upstream repository and a workspace whose clone of it is already in `downloads/`.
    ///
    /// The clone points at the upstream through a file path, so `sync --update` and
    /// `rollback` exercise real git without touching the network.
    final class Fixture {
        let root: URL
        let upstream: URL
        let workspace: Workspace
        let clone: URL

        init(skills: [String]) throws {
            root = FileManager.default.temporaryDirectory
                .appending(path: "skiller-rollback-\(UUID().uuidString)", directoryHint: .isDirectory)
            upstream = root.appending(path: "upstream", directoryHint: .isDirectory)
            workspace = try Workspace.create(at: root.appending(path: "ws", directoryHint: .isDirectory))
            clone = workspace.layout.repositoryDirectory(host: "example.com", owner: "o", repo: "r")
            self.skills = skills
        }

        let skills: [String]

        deinit {
            try? FileManager.default.removeItem(at: root)
        }

        func git(_ arguments: [String], in directory: URL) async throws -> String {
            try await ProcessRunner.check(
                "git",
                ["-c", "user.name=test", "-c", "user.email=test@example.invalid"] + arguments,
                workingDirectory: directory
            ).output
        }

        /// Writes `version` into every skill's SKILL.md upstream and commits it.
        @discardableResult
        func commitUpstream(version: String) async throws -> String {
            for skill in skills {
                let directory = upstream.appending(path: "skills/\(skill)", directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try "---\nname: \(skill)\n---\n\(version)\n".write(
                    to: directory.appending(path: "SKILL.md", directoryHint: .notDirectory),
                    atomically: true,
                    encoding: .utf8
                )
            }
            _ = try await git(["add", "-A"], in: upstream)
            _ = try await git(["commit", "--quiet", "-m", version], in: upstream)
            return try await git(["rev-parse", "HEAD"], in: upstream)
        }

        /// Creates the upstream at a first commit, clones it and locks every skill there.
        func setUp() async throws -> String {
            try FileManager.default.createDirectory(at: upstream, withIntermediateDirectories: true)
            _ = try await git(["init", "--quiet", "--initial-branch=main"], in: upstream)
            let first = try await commitUpstream(version: "v1")

            try FileManager.default.createDirectory(
                at: clone.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            _ = try await git(
                ["clone", "--quiet", upstream.path(percentEncoded: false), clone.path(percentEncoded: false)],
                in: root
            )

            var workspace = workspace
            for skill in skills {
                let entry = LockedSkill(
                    name: skill,
                    host: "example.com",
                    owner: "o",
                    repo: "r",
                    skillPath: "skills/\(skill)",
                    commit: first
                )
                try LinkManager.createLink(
                    at: workspace.layout.installLink(name: skill),
                    to: workspace.layout.skillDirectory(for: entry)
                )
                try workspace.updateLock { $0.upsert(entry) }
            }
            return first
        }

        func content(of skill: String) throws -> String {
            try String(
                contentsOf: workspace.layout.installLink(name: skill)
                    .appending(path: "SKILL.md", directoryHint: .notDirectory),
                encoding: .utf8
            )
        }

        func installer() throws -> SkillInstaller {
            SkillInstaller(workspace: try Workspace(root: workspace.root))
        }
    }

    @Test("an update records the commit it left, and rollback returns to it")
    func rollbackAfterUpdate() async throws {
        let fixture = try Fixture(skills: ["alpha"])
        let first = try await fixture.setUp()
        let second = try await fixture.commitUpstream(version: "v2")

        var installer = try fixture.installer()
        _ = try await installer.sync(update: true)
        #expect(installer.workspace.lock["alpha"]?.commit == second)
        #expect(installer.workspace.lock["alpha"]?.previousCommit == first)
        #expect(try fixture.content(of: "alpha").contains("v2"))

        let outcome = try await installer.rollback(name: "alpha")
        #expect(outcome.from == second)
        #expect(outcome.to == first)
        #expect(installer.workspace.lock["alpha"]?.commit == first)
        #expect(try fixture.content(of: "alpha").contains("v1"))
    }

    @Test("a second rollback undoes the first")
    func rollbackToggles() async throws {
        let fixture = try Fixture(skills: ["alpha"])
        _ = try await fixture.setUp()
        let second = try await fixture.commitUpstream(version: "v2")

        var installer = try fixture.installer()
        _ = try await installer.sync(update: true)
        _ = try await installer.rollback(name: "alpha")
        _ = try await installer.rollback(name: "alpha")

        #expect(installer.workspace.lock["alpha"]?.commit == second)
        #expect(try fixture.content(of: "alpha").contains("v2"))
    }

    @Test("skills sharing a clone all record their previous commit and roll back together")
    func siblingsMoveTogether() async throws {
        let fixture = try Fixture(skills: ["alpha", "beta"])
        let first = try await fixture.setUp()
        try await fixture.commitUpstream(version: "v2")

        var installer = try fixture.installer()
        _ = try await installer.sync(update: true)
        // Only the first entry sees HEAD move; the second must still learn where it came from.
        #expect(installer.workspace.lock["beta"]?.previousCommit == first)

        let outcome = try await installer.rollback(name: "alpha")
        #expect(outcome.alsoMoved == ["beta"])
        #expect(installer.workspace.lock["beta"]?.commit == first)
        #expect(try fixture.content(of: "beta").contains("v1"))
    }

    @Test("a skill that was never updated has nothing to roll back to")
    func nothingToRollBackTo() async throws {
        let fixture = try Fixture(skills: ["alpha"])
        _ = try await fixture.setUp()

        var installer = try fixture.installer()
        await #expect(throws: SkillInstaller.RollbackError.self) {
            try await installer.rollback(name: "alpha")
        }
    }

    @Test("uncommitted edits in the clone block a rollback instead of being mixed in")
    func localChangesBlock() async throws {
        let fixture = try Fixture(skills: ["alpha"])
        _ = try await fixture.setUp()
        try await fixture.commitUpstream(version: "v2")

        var installer = try fixture.installer()
        _ = try await installer.sync(update: true)
        try "edited\n".write(
            to: fixture.clone.appending(path: "skills/alpha/SKILL.md", directoryHint: .notDirectory),
            atomically: true,
            encoding: .utf8
        )

        await #expect(throws: SkillInstaller.RollbackError.self) {
            try await installer.rollback(name: "alpha")
        }
        #expect(try fixture.content(of: "alpha") == "edited\n")
    }

    @Test("an update that does not move keeps the earlier way back")
    func previousCommitSurvivesNoOpUpdate() {
        let locked = LockedSkill(name: "s", commit: "bbb", previousCommit: "aaa")
        #expect(SkillInstaller.previousCommit(locked: locked, movingTo: "bbb") == "aaa")
        #expect(SkillInstaller.previousCommit(locked: locked, movingTo: "ccc") == "bbb")
        #expect(SkillInstaller.previousCommit(locked: nil, movingTo: "ccc") == nil)
    }
}
