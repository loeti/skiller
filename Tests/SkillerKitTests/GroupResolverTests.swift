import Foundation
import Testing

@testable import SkillerKit

@Suite("Nested groups and project apply")
struct GroupResolverTests {
    /// A workspace with real directories and symlinks, removed when the test finishes.
    ///
    /// Resolution is entirely a question of what is on disk, so there is nothing meaningful to
    /// fake here — every test builds the tree it needs.
    final class Fixture {
        let root: URL
        let workspace: Workspace

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appending(path: "skiller-groups-\(UUID().uuidString)", directoryHint: .isDirectory)
            workspace = try Workspace.create(at: root)
        }

        deinit {
            try? FileManager.default.removeItem(at: root)
        }

        /// Creates `installs/<name>` as a real directory holding a SKILL.md, standing in for
        /// the symlink into a clone that `add` would make. Resolution treats both alike.
        @discardableResult
        func install(_ name: String) throws -> URL {
            let url = workspace.layout.installLink(name: name)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try "---\nname: \(name)\n---\n".write(
                to: url.appending(path: "SKILL.md", directoryHint: .notDirectory),
                atomically: true,
                encoding: .utf8
            )
            return url
        }

        /// Links an install into a group, the way `skiller link` does.
        func link(_ name: String, into group: String) throws {
            try LinkManager.createLink(
                at: workspace.layout.groupLink(group: group, name: name),
                to: workspace.layout.installLink(name: name)
            )
        }

        /// Links a group into another group.
        func linkGroup(_ target: String, into group: String) throws {
            let installer = SkillInstaller(workspace: workspace)
            try installer.linkGroup(target, into: group)
        }

        func makeGroup(_ group: String) throws {
            try FileManager.default.createDirectory(
                at: workspace.layout.groupDirectory(group),
                withIntermediateDirectories: true
            )
        }

        func project() throws -> URL {
            let url = root.appending(path: "project", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
    }

    // MARK: - Resolution

    @Test("a group link is followed down to the skills behind it")
    func flattensNestedGroups() throws {
        let fixture = try Fixture()
        for name in ["swift-concurrency", "swiftui-expert"] { try fixture.install(name) }
        try fixture.link("swift-concurrency", into: "swift")
        try fixture.link("swiftui-expert", into: "swiftui")
        try fixture.makeGroup("ios")
        try fixture.linkGroup("swift", into: "ios")
        try fixture.linkGroup("swiftui", into: "ios")

        let resolution = try GroupResolver.resolve(groups: ["ios"], in: fixture.workspace)

        #expect(resolution.skills.map(\.name) == ["swift-concurrency", "swiftui-expert"])
        // The intermediate levels are gone; every path points straight at an install.
        for skill in resolution.skills {
            #expect(skill.installPath == fixture.workspace.layout.installLink(name: skill.name))
        }
        #expect(!resolution.hasProblems)
    }

    @Test("nesting keeps working several levels down")
    func followsDeepNesting() throws {
        let fixture = try Fixture()
        try fixture.install("deep-skill")
        try fixture.link("deep-skill", into: "level-c")
        try fixture.makeGroup("level-b")
        try fixture.linkGroup("level-c", into: "level-b")
        try fixture.makeGroup("level-a")
        try fixture.linkGroup("level-b", into: "level-a")

        let resolution = try GroupResolver.resolve(groups: ["level-a"], in: fixture.workspace)
        #expect(resolution.skills.map(\.name) == ["deep-skill"])
        #expect(resolution.skills.first?.sourceGroup == "level-c")
    }

    @Test("a plain subdirectory is a group too")
    func followsRealSubdirectories() throws {
        let fixture = try Fixture()
        try fixture.install("bkt")
        try fixture.link("bkt", into: "vpbank/bkt-group")

        let resolution = try GroupResolver.resolve(groups: ["vpbank"], in: fixture.workspace)
        #expect(resolution.skills.map(\.name) == ["bkt"])
    }

    @Test("one skill reached through two groups resolves once")
    func deduplicatesSharedSkills() throws {
        let fixture = try Fixture()
        try fixture.install("shared")
        try fixture.link("shared", into: "alpha")
        try fixture.link("shared", into: "beta")

        let resolution = try GroupResolver.resolve(groups: ["alpha", "beta"], in: fixture.workspace)
        #expect(resolution.skills.count == 1)
        // The group that introduced it wins, and the requested order decides which that is.
        #expect(resolution.skills.first?.sourceGroup == "alpha")
    }

    @Test("a diamond does not report a cycle")
    func toleratesDiamonds() throws {
        let fixture = try Fixture()
        try fixture.install("leaf")
        try fixture.link("leaf", into: "shared")
        try fixture.makeGroup("left")
        try fixture.makeGroup("right")
        try fixture.linkGroup("shared", into: "left")
        try fixture.linkGroup("shared", into: "right")
        try fixture.makeGroup("top")
        try fixture.linkGroup("left", into: "top")
        try fixture.linkGroup("right", into: "top")

        let resolution = try GroupResolver.resolve(groups: ["top"], in: fixture.workspace)
        #expect(resolution.skills.map(\.name) == ["leaf"])
        #expect(resolution.cycles.isEmpty)
    }

    @Test("a circular group reference is reported instead of looping forever")
    func detectsCycles() throws {
        let fixture = try Fixture()
        try fixture.install("a-skill")
        try fixture.link("a-skill", into: "alpha")
        try fixture.makeGroup("beta")
        try fixture.linkGroup("beta", into: "alpha")
        try fixture.linkGroup("alpha", into: "beta")

        let resolution = try GroupResolver.resolve(groups: ["alpha"], in: fixture.workspace)

        #expect(resolution.cycles == ["alpha → beta → alpha"])
        // Everything outside the loop still resolves.
        #expect(resolution.skills.map(\.name) == ["a-skill"])
    }

    @Test("a dangling link is reported, and the rest of the group still resolves")
    func reportsDeadLinks() throws {
        let fixture = try Fixture()
        try fixture.install("alive")
        try fixture.link("alive", into: "group")
        try LinkManager.createLink(
            at: fixture.workspace.layout.groupLink(group: "group", name: "gone"),
            to: fixture.workspace.layout.installLink(name: "gone")
        )

        let resolution = try GroupResolver.resolve(groups: ["group"], in: fixture.workspace)
        #expect(resolution.skills.map(\.name) == ["alive"])
        #expect(resolution.deadLinks == ["skills/group/gone"])
    }

    @Test("a skill directory copied in by hand is reported, not deployed")
    func reportsUnadoptedDirectories() throws {
        let fixture = try Fixture()
        let byHand = fixture.workspace.layout.groupDirectory("group/copied-in")
        try FileManager.default.createDirectory(at: byHand, withIntermediateDirectories: true)
        try "---\nname: copied-in\n---\n".write(
            to: byHand.appending(path: "SKILL.md", directoryHint: .notDirectory),
            atomically: true,
            encoding: .utf8
        )

        let resolution = try GroupResolver.resolve(groups: ["group"], in: fixture.workspace)
        #expect(resolution.skills.isEmpty)
        #expect(resolution.unadopted == ["skills/group/copied-in"])
    }

    @Test("two different targets wanting one name keep the first, deterministically")
    func reportsNameCollisions() throws {
        let fixture = try Fixture()
        try fixture.install("skill")
        // Only a hand-made link can produce this: installs/ is flat, so its names are unique.
        let outside = fixture.root.appending(path: "elsewhere/skill", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try fixture.link("skill", into: "alpha")
        try LinkManager.createLink(
            at: fixture.workspace.layout.groupLink(group: "beta", name: "alias"),
            to: outside
        )

        let resolution = try GroupResolver.resolve(groups: ["alpha", "beta"], in: fixture.workspace)
        #expect(resolution.skills.count == 1)
        #expect(resolution.skills.first?.installPath == fixture.workspace.layout.installLink(name: "skill"))
        #expect(resolution.collisions.count == 1)
    }

    @Test("an unknown group names the ones that exist")
    func rejectsUnknownGroup() throws {
        let fixture = try Fixture()
        try fixture.install("s")
        try fixture.link("s", into: "real")

        #expect(throws: GroupResolver.UnknownGroupError.self) {
            try GroupResolver.resolve(groups: ["imaginary"], in: fixture.workspace)
        }
    }

    @Test("a trailing slash from tab completion is not a different group")
    func normalizesGroupNames() throws {
        let fixture = try Fixture()
        try fixture.install("s")
        try fixture.link("s", into: "group")

        let resolution = try GroupResolver.resolve(groups: ["group/"], in: fixture.workspace)
        #expect(resolution.skills.map(\.name) == ["s"])
    }

    // MARK: - Linking groups

    @Test("a group linked into itself is refused")
    func refusesSelfNesting() throws {
        let fixture = try Fixture()
        try fixture.install("s")
        try fixture.link("s", into: "ios")

        let installer = SkillInstaller(workspace: fixture.workspace)
        #expect(throws: SkillInstaller.InstallError.self) {
            try installer.linkGroup("ios", into: "ios")
        }
        // ... and so is nesting it inside its own subtree, which loops the directory tree.
        try fixture.makeGroup("ios/sub")
        #expect(throws: SkillInstaller.InstallError.self) {
            try installer.linkGroup("ios", into: "ios/sub")
        }
    }

    @Test("a group link takes the target's last path component as its name")
    func namesGroupLinkAfterTarget() throws {
        let fixture = try Fixture()
        try fixture.install("s")
        try fixture.link("s", into: "vpbank/bkt")
        try fixture.makeGroup("ios")

        let installer = SkillInstaller(workspace: fixture.workspace)
        let name = try installer.linkGroup("vpbank/bkt", into: "ios")
        #expect(name == "bkt")

        let resolution = try GroupResolver.resolve(groups: ["ios"], in: fixture.workspace)
        #expect(resolution.skills.map(\.name) == ["s"])
    }

    @Test("unlinking a group link leaves skill membership alone")
    func unlinkDoesNotTouchUnrelatedLockEntries() throws {
        let fixture = try Fixture()
        try fixture.install("swift")
        try fixture.link("swift", into: "language")
        try fixture.makeGroup("ios")

        var workspace = fixture.workspace
        try workspace.updateLock { lock in
            lock.upsert(LockedSkill(name: "swift", origin: .local, groups: ["language"]))
        }
        var installer = SkillInstaller(workspace: workspace)
        // A group happening to share a name with an installed skill.
        try installer.linkGroup("language", into: "ios")
        let groupLink = fixture.workspace.layout.groupLink(group: "ios", name: "language")
        #expect(LinkManager.isSymlink(groupLink))

        try installer.unlink(name: "language", from: "ios")
        #expect(!LinkManager.isSymlink(groupLink))
        // The install's own membership is untouched.
        #expect(installer.workspace.lock["swift"]?.groups == ["language"])

        // A real skill link, on the other hand, still updates the lock.
        try installer.unlink(name: "swift", from: "language")
        #expect(installer.workspace.lock["swift"]?.groups == [])
    }

    @Test("doctor does not mistake a group link for a broken skill link")
    func doctorAcceptsGroupLinks() throws {
        let fixture = try Fixture()
        try fixture.install("s")
        try fixture.link("s", into: "swift")
        try fixture.makeGroup("ios")
        try fixture.linkGroup("swift", into: "ios")

        let issues = WorkspaceDoctor.diagnose(fixture.workspace)
        #expect(!issues.contains { $0.path == "skills/ios/swift" })
    }

    // MARK: - Apply

    @Test("groups are applied flat into .claude/skills")
    func appliesFlattened() throws {
        let fixture = try Fixture()
        for name in ["swift-concurrency", "swiftui-expert"] { try fixture.install(name) }
        try fixture.link("swift-concurrency", into: "swift")
        try fixture.link("swiftui-expert", into: "swiftui")
        try fixture.makeGroup("ios")
        try fixture.linkGroup("swift", into: "ios")
        try fixture.linkGroup("swiftui", into: "ios")

        let project = try fixture.project()
        let applier = ProjectApplier(projectRoot: project, workspace: fixture.workspace)
        let resolution = try GroupResolver.resolve(groups: ["ios"], in: fixture.workspace)
        let report = try applier.apply(resolution.skills)

        #expect(report.created.sorted() == ["swift-concurrency", "swiftui-expert"])
        let deployed = LinkManager.symlinks(in: applier.skillsDirectory).map(\.lastPathComponent)
        #expect(deployed == ["swift-concurrency", "swiftui-expert"])
        // Flat: no group directories survive the flattening.
        let contents = try FileManager.default.contentsOfDirectory(
            at: applier.skillsDirectory,
            includingPropertiesForKeys: nil
        )
        #expect(contents.count == 2)
    }

    @Test("project links are absolute and point at installs/, not at the clone")
    func writesAbsoluteLinksToInstalls() throws {
        let fixture = try Fixture()
        try fixture.install("skill")
        try fixture.link("skill", into: "group")

        let project = try fixture.project()
        let applier = ProjectApplier(projectRoot: project, workspace: fixture.workspace)
        let resolution = try GroupResolver.resolve(groups: ["group"], in: fixture.workspace)
        _ = try applier.apply(resolution.skills)

        let link = applier.skillsDirectory.appending(path: "skill", directoryHint: .notDirectory)
        let destination = try FileManager.default.destinationOfSymbolicLink(
            atPath: link.path(percentEncoded: false)
        )
        #expect(destination.hasPrefix("/"))
        #expect(destination.hasSuffix("/installs/skill"))
    }

    @Test("applying twice changes nothing the second time")
    func isIdempotent() throws {
        let fixture = try Fixture()
        try fixture.install("skill")
        try fixture.link("skill", into: "group")

        let project = try fixture.project()
        let applier = ProjectApplier(projectRoot: project, workspace: fixture.workspace)
        let resolution = try GroupResolver.resolve(groups: ["group"], in: fixture.workspace)

        _ = try applier.apply(resolution.skills)
        let second = try applier.apply(resolution.skills)
        #expect(second.created.isEmpty)
        #expect(second.unchanged == ["skill"])
    }

    @Test("a dry run reports the same thing but writes nothing")
    func dryRunWritesNothing() throws {
        let fixture = try Fixture()
        try fixture.install("skill")
        try fixture.link("skill", into: "group")

        let project = try fixture.project()
        let applier = ProjectApplier(projectRoot: project, workspace: fixture.workspace)
        let resolution = try GroupResolver.resolve(groups: ["group"], in: fixture.workspace)

        let planned = try applier.apply(resolution.skills, dryRun: true)
        #expect(planned.created == ["skill"])
        #expect(!FileManager.default.fileExists(atPath: applier.skillsDirectory.path(percentEncoded: false)))

        let real = try applier.apply(resolution.skills)
        #expect(real.created == planned.created)
    }

    @Test("what the project put there itself is left alone")
    func preservesForeignEntries() throws {
        let fixture = try Fixture()
        try fixture.install("skill")
        try fixture.link("skill", into: "group")

        let project = try fixture.project()
        let applier = ProjectApplier(projectRoot: project, workspace: fixture.workspace)
        let handWritten = applier.skillsDirectory.appending(path: "project-own", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: handWritten, withIntermediateDirectories: true)

        let resolution = try GroupResolver.resolve(groups: ["group"], in: fixture.workspace)
        _ = try applier.apply(resolution.skills)
        #expect(Workspace.isDirectory(handWritten))

        // Even --clean only removes symlinks; real content is never deleted.
        _ = try applier.apply(resolution.skills, clean: true)
        #expect(Workspace.isDirectory(handWritten))
    }

    @Test("a link from an earlier apply is reported, and dropped only with --clean")
    func reportsAndCleansStaleLinks() throws {
        let fixture = try Fixture()
        try fixture.install("old")
        try fixture.install("new")
        try fixture.link("old", into: "before")
        try fixture.link("new", into: "after")

        let project = try fixture.project()
        let applier = ProjectApplier(projectRoot: project, workspace: fixture.workspace)
        _ = try applier.apply(try GroupResolver.resolve(groups: ["before"], in: fixture.workspace).skills)

        let after = try GroupResolver.resolve(groups: ["after"], in: fixture.workspace).skills
        let kept = try applier.apply(after)
        #expect(kept.stale == ["old"])
        #expect(LinkManager.symlinks(in: applier.skillsDirectory).count == 2)

        let cleaned = try applier.apply(after, clean: true)
        #expect(cleaned.removed == ["old"])
        #expect(LinkManager.symlinks(in: applier.skillsDirectory).map(\.lastPathComponent) == ["new"])
    }

    @Test("a real directory in the way is reported, never overwritten")
    func refusesToClobberRealDirectories() throws {
        let fixture = try Fixture()
        try fixture.install("skill")
        try fixture.link("skill", into: "group")

        let project = try fixture.project()
        let applier = ProjectApplier(projectRoot: project, workspace: fixture.workspace)
        let occupied = applier.skillsDirectory.appending(path: "skill", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: true)

        let resolution = try GroupResolver.resolve(groups: ["group"], in: fixture.workspace)
        let report = try applier.apply(resolution.skills)
        #expect(report.blocked == ["skill"])
        #expect(!LinkManager.isSymlink(occupied))
    }

    // MARK: - .gitignore

    @Test(".claude/ is appended to an existing .gitignore exactly once")
    func appendsGitignoreEntry() throws {
        let fixture = try Fixture()
        let project = try fixture.project()
        let gitignore = project.appending(path: ".gitignore", directoryHint: .notDirectory)
        // No trailing newline: the entry must not be glued onto '.build'.
        try ".build".write(to: gitignore, atomically: true, encoding: .utf8)

        let applier = ProjectApplier(projectRoot: project, workspace: fixture.workspace)
        #expect(try applier.ensureGitignore(dryRun: false) == .appended)
        #expect(try String(contentsOf: gitignore, encoding: .utf8) == ".build\n.claude/\n")

        #expect(try applier.ensureGitignore(dryRun: false) == .alreadyCovered)
    }

    @Test("an existing entry is recognised in any spelling git accepts")
    func recognisesExistingEntries() {
        for spelling in [".claude/", ".claude", "/.claude", "/.claude/", "  .claude/  "] {
            #expect(ProjectApplier.ignoresClaudeDirectory("*.log\n\(spelling)\n"), "\(spelling)")
        }
        // A comment mentioning it is not an entry, and a negation re-includes it.
        #expect(!ProjectApplier.ignoresClaudeDirectory("# .claude/\n"))
        #expect(!ProjectApplier.ignoresClaudeDirectory("!.claude/\n"))
        #expect(!ProjectApplier.ignoresClaudeDirectory(".claude-extra/\n"))
    }

    @Test("no .gitignore is created outside a git working tree")
    func skipsGitignoreOutsideRepository() throws {
        let fixture = try Fixture()
        let project = try fixture.project()
        let applier = ProjectApplier(projectRoot: project, workspace: fixture.workspace)
        #expect(try applier.ensureGitignore(dryRun: false) == .skippedNoRepository)
        #expect(!FileManager.default.fileExists(atPath: applier.gitignoreFile.path(percentEncoded: false)))

        try FileManager.default.createDirectory(
            at: project.appending(path: ".git", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        #expect(try applier.ensureGitignore(dryRun: false) == .created)
        #expect(try String(contentsOf: applier.gitignoreFile, encoding: .utf8) == ".claude/\n")
    }
}
