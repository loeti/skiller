import Foundation
import Testing

@testable import SkillerKit

@Suite("Lock file, discovery and workspace resolution")
struct WorkspaceTests {
    // MARK: - Lock file

    @Test("a lock file round-trips through JSON")
    func lockFileRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "lock-\(UUID().uuidString).json", directoryHint: .notDirectory)
        defer { try? FileManager.default.removeItem(at: url) }

        let original = LockFile(skills: [
            LockedSkill(
                name: "swiftui-pro",
                host: "github.com",
                owner: "twostraws",
                repo: "swiftui-agent-skill",
                skillPath: "swiftui-pro",
                commit: "be297ff",
                groups: ["swiftui", "ios"]
            ),
            LockedSkill(name: "bkt", origin: .local, groups: ["vpbank"]),
        ])

        try original.write(to: url)
        let restored = try LockFile.read(from: url)
        #expect(restored.skills.count == 2)
        #expect(restored["bkt"]?.origin == .local)
        #expect(restored["swiftui-pro"]?.groups == ["ios", "swiftui"])
    }

    @Test("entries stay sorted so the file diffs cleanly")
    func keepsEntriesSorted() {
        var lock = LockFile()
        lock.upsert(LockedSkill(name: "zebra", origin: .local))
        lock.upsert(LockedSkill(name: "alpha", origin: .local))
        #expect(lock.skills.map(\.name) == ["alpha", "zebra"])
    }

    @Test("a missing lock file reads as empty rather than failing")
    func toleratesMissingFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "does-not-exist-\(UUID().uuidString).json", directoryHint: .notDirectory)
        #expect(try LockFile.read(from: url).skills.isEmpty)
    }

    @Test("a lock file written before 'origin' existed still reads as git")
    func defaultsOriginForOlderFiles() throws {
        let json = """
            {"version":1,"skills":[{"name":"x","host":"github.com","owner":"o","repo":"r",
             "skillPath":"s","commit":"abc","groups":[],"installedAt":"2026-08-01T00:00:00Z"}]}
            """
        let lock = try LockFile.decoder.decode(LockFile.self, from: Data(json.utf8))
        #expect(lock["x"]?.origin == .git)
    }

    @Test("only git entries count as referenced repositories")
    func referencedReposIgnoresLocal() {
        let lock = LockFile(skills: [
            LockedSkill(name: "a", host: "github.com", owner: "o", repo: "r", commit: "1"),
            LockedSkill(name: "b", origin: .local),
        ])
        #expect(lock.referencedRepos == ["github.com/o/r"])
    }

    // MARK: - Licence resolution

    @Test("what the skill declares about itself wins")
    func manifestLicenseWins() {
        let resolution = LicenseResolver.resolve(
            manifest: SkillManifest(name: "s", license: "MIT"),
            registry: RegistryRecord(
                name: "s", repo: "o/r", path: "s", branch: "main", stars: 0,
                license: "Apache-2.0", distribution: "permissive", category: "", description: ""
            ),
            repositoryDirectory: nil
        )
        #expect(resolution.license == "MIT")
        #expect(resolution.source == .manifest)
        // The registry's classification is still recorded — 'restricted' matters either way.
        #expect(resolution.distribution == "permissive")
    }

    @Test("the registry fills in when the skill declares nothing")
    func registryLicenseIsFallback() {
        let resolution = LicenseResolver.resolve(
            manifest: SkillManifest(name: "s"),
            registry: RegistryRecord(
                name: "s", repo: "o/r", path: "s", branch: "main", stars: 0,
                license: "NOASSERTION", distribution: "restricted", category: "", description: ""
            ),
            repositoryDirectory: nil
        )
        #expect(resolution.license == "NOASSERTION")
        #expect(resolution.source == .registry)
    }

    @Test("a licence file is reported as evidence, never guessed at")
    func licenseFileIsEvidenceOnly() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "licence-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try "MIT License\n\nPermission is hereby granted…".write(
            to: directory.appending(path: "LICENSE", directoryHint: .notDirectory),
            atomically: true,
            encoding: .utf8
        )

        let resolution = LicenseResolver.resolve(
            manifest: SkillManifest(name: "s"),
            registry: nil,
            repositoryDirectory: directory
        )
        #expect(resolution.licenseFile == "LICENSE")
        #expect(resolution.source == .repositoryFile)
        // The file says "MIT License", but claiming MIT from prose would be a guess.
        #expect(resolution.license == "unidentified (LICENSE)")
    }

    @Test("nothing anywhere means nothing recorded")
    func noLicenseAnywhere() {
        let resolution = LicenseResolver.resolve(manifest: nil, registry: nil, repositoryDirectory: nil)
        #expect(resolution.license == nil)
        #expect(resolution.source == nil)
    }

    @Test("an unclear or restricted licence is flagged for review")
    func flagsEntriesNeedingReview() {
        #expect(LockedSkill(name: "a", license: nil).needsLicenseReview)
        #expect(LockedSkill(name: "b", license: "NOASSERTION").needsLicenseReview)
        #expect(LockedSkill(name: "c", license: "MIT", distribution: "restricted").needsLicenseReview)
        #expect(!LockedSkill(name: "d", license: "MIT", distribution: "permissive").needsLicenseReview)
    }

    @Test("licence fields survive a lock file round-trip")
    func licenseRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "lic-\(UUID().uuidString).json", directoryHint: .notDirectory)
        defer { try? FileManager.default.removeItem(at: url) }

        try LockFile(skills: [
            LockedSkill(
                name: "s", host: "github.com", owner: "o", repo: "r", skillPath: "s",
                commit: "abc", license: "MIT", licenseSource: .manifest,
                distribution: "permissive", licenseFile: "LICENSE"
            )
        ]).write(to: url)

        let entry = try #require(LockFile.read(from: url)["s"])
        #expect(entry.license == "MIT")
        #expect(entry.licenseSource == .manifest)
        #expect(entry.distribution == "permissive")
        #expect(entry.licenseFile == "LICENSE")
    }

    @Test("a lock file written before licences existed still reads")
    func toleratesLockWithoutLicense() throws {
        let json = """
            {"version":1,"skills":[{"name":"x","origin":"git","host":"github.com","owner":"o",
             "repo":"r","skillPath":"s","commit":"abc","groups":[],
             "installedAt":"2026-08-01T00:00:00Z"}]}
            """
        let lock = try LockFile.decoder.decode(LockFile.self, from: Data(json.utf8))
        #expect(lock["x"]?.license == nil)
        #expect(lock["x"]?.needsLicenseReview == true)
    }

    // MARK: - Discovery

    @Test("an identifier matches by full path or by directory name")
    func resolvesIdentifier() throws {
        let skills = [
            DiscoveredSkill(relativePath: "skills/swiftui", manifest: SkillManifest(name: "swiftui")),
            DiscoveredSkill(relativePath: "swiftui-pro", manifest: SkillManifest(name: "swiftui-pro")),
        ]
        #expect(try SkillDiscovery.resolve(identifier: "skills/swiftui", in: skills, repoSlug: "o/r").relativePath == "skills/swiftui")
        #expect(try SkillDiscovery.resolve(identifier: "swiftui", in: skills, repoSlug: "o/r").relativePath == "skills/swiftui")
        #expect(try SkillDiscovery.resolve(identifier: "swiftui-pro", in: skills, repoSlug: "o/r").relativePath == "swiftui-pro")
    }

    @Test("an ambiguous directory name is an error, not a coin flip")
    func rejectsAmbiguousName() {
        let skills = [
            DiscoveredSkill(relativePath: "a/swiftui", manifest: SkillManifest(name: "swiftui")),
            DiscoveredSkill(relativePath: "b/swiftui", manifest: SkillManifest(name: "swiftui")),
        ]
        #expect(throws: SkillDiscovery.ResolutionError.self) {
            try SkillDiscovery.resolve(identifier: "swiftui", in: skills, repoSlug: "o/r")
        }
    }

    @Test("no identifier works only when the repository holds exactly one skill")
    func requiresPickWhenAmbiguous() throws {
        let single = [DiscoveredSkill(relativePath: "", manifest: SkillManifest(name: "root"))]
        #expect(try SkillDiscovery.resolve(identifier: nil, in: single, repoSlug: "o/r").relativePath == "")

        let many = single + [DiscoveredSkill(relativePath: "other", manifest: SkillManifest(name: "other"))]
        #expect(throws: SkillDiscovery.ResolutionError.self) {
            try SkillDiscovery.resolve(identifier: nil, in: many, repoSlug: "o/r")
        }
    }

    @Test("SKILL.md files are found on disk with correct relative paths")
    func discoversSkillsOnDisk() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "repo-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        for path in ["swiftui-pro", "nested/deep/skill", ".git/objects", "node_modules/pkg"] {
            let directory = root.appending(path: path, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try "---\nname: \(directory.lastPathComponent)\n---\n".write(
                to: directory.appending(path: "SKILL.md", directoryHint: .notDirectory),
                atomically: true,
                encoding: .utf8
            )
        }

        let found = SkillDiscovery.discoverSkills(in: root)
        let paths = found.map(\.relativePath)
        #expect(paths.contains("swiftui-pro"))
        #expect(paths.contains("nested/deep/skill"))
        // Vendored and VCS directories are never skill sources.
        #expect(!paths.contains { $0.hasPrefix(".git") })
        #expect(!paths.contains { $0.hasPrefix("node_modules") })
    }

    // MARK: - Workspace resolution

    @Test("an explicit path wins over the environment")
    func explicitPathWins() throws {
        let explicit = FileManager.default.temporaryDirectory
            .appending(path: "explicit-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: explicit, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: explicit) }

        let resolved = try Workspace.resolveRoot(
            explicit: explicit.path(percentEncoded: false),
            environment: [Workspace.environmentVariable: "/somewhere/else"]
        )
        #expect(resolved.standardizedFileURL == explicit.standardizedFileURL)
    }

    @Test("the environment variable is used when no path is given")
    func environmentIsUsed() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "env-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let resolved = try Workspace.resolveRoot(
            explicit: nil,
            environment: [Workspace.environmentVariable: root.path(percentEncoded: false)]
        )
        #expect(resolved.standardizedFileURL == root.standardizedFileURL)
    }

    @Test("the nearest ancestor holding .skiller is found")
    func walksUpToMarker() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "walk-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try Workspace.create(at: root)

        let deep = root.appending(path: "skills/group/nested", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)

        let resolved = try Workspace.resolveRoot(explicit: nil, environment: [:], currentDirectory: deep)
        #expect(resolved.standardizedFileURL == root.standardizedFileURL)
    }

    @Test("an older config adopts sources added since, and says it changed")
    func migratesConfigForward() {
        var old = WorkspaceConfig(version: 1, defaultSources: [.skillsSh, .gitHub], cloneDepth: 1)
        // Called outside #expect: the macro captures its argument immutably.
        let changed = old.migrate()
        #expect(changed)
        #expect(old.version == WorkspaceConfig.currentVersion)
        #expect(old.defaultSources.contains(.registry))
        // Existing choices survive; only unknown sources are appended.
        #expect(old.defaultSources.prefix(2) == [.skillsSh, .gitHub])
        // Idempotent — a second pass reports no change.
        let changedAgain = old.migrate()
        #expect(!changedAgain)
    }

    @Test("the migrated config is written back to disk")
    func persistsMigratedConfig() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "migrate-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try Workspace.create(at: root)

        let layout = Layout(root: root)
        try WorkspaceConfig(version: 1, defaultSources: [.skillsSh], cloneDepth: 1)
            .write(to: layout.configFile)

        _ = try Workspace(root: root)

        let reloaded = try WorkspaceConfig.read(from: layout.configFile)
        #expect(reloaded.version == WorkspaceConfig.currentVersion)
        #expect(reloaded.defaultSources.contains(.registry))
    }

    @Test("creating a workspace lays out all four directories")
    func createsSkeleton() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "create-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let workspace = try Workspace.create(at: root)
        for directory in [
            workspace.layout.stateDirectory,
            workspace.layout.downloadsDirectory,
            workspace.layout.installsDirectory,
            workspace.layout.skillsDirectory,
        ] {
            #expect(Workspace.isDirectory(directory))
        }
        #expect(workspace.lock.skills.isEmpty)
        #expect(workspace.config.cloneDepth == 1)
    }
}
