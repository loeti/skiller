import Foundation

/// Clone → install link → group link → lock entry.
///
/// This is the only place that mutates the workspace, so every command shares the same
/// collision rules and the lock file can never drift from what `add` and `remove` did.
public struct SkillInstaller: Sendable {
    public private(set) var workspace: Workspace
    private let git: GitClient
    private let registry: RegistryShardIndex

    public init(
        workspace: Workspace,
        git: GitClient = GitClient(),
        registry: RegistryShardIndex = RegistryShardIndex()
    ) {
        self.workspace = workspace
        self.git = git
        self.registry = registry
    }

    public enum InstallError: Error, CustomStringConvertible {
        case nameTaken(name: String, existing: String, incoming: String)
        case notInstalled(name: String)
        case noSkillsInRepository(String)
        case localRequiresPrune(name: String)
        case notAdoptable(path: String, reason: String)
        case noSuchGroup(String)
        case groupContainsItself(group: String, target: String)
        case ambiguousLinkTarget(String)

        public var description: String {
            switch self {
            case .nameTaken(let name, let existing, let incoming):
                """
                '\(name)' is already installed from \(existing); \(incoming) wants the same name.
                Re-run with --as <name> — the usual convention is '\(name)@<owner>'.
                """
            case .notInstalled(let name):
                "'\(name)' is not installed."
            case .noSkillsInRepository(let slug):
                "\(slug) contains no \(SkillManifest.fileName)."
            case .localRequiresPrune(let name):
                """
                '\(name)' was adopted from a local directory, so installs/\(name) holds the only \
                copy of its content. Re-run with --prune to delete it.
                """
            case .notAdoptable(let path, let reason):
                "Cannot adopt '\(path)': \(reason)."
            case .noSuchGroup(let group):
                "No group 'skills/\(group)'."
            case .groupContainsItself(let group, let target):
                """
                Linking '\(target)' into '\(group)' would put it inside itself, which makes the \
                directory tree infinite. Nesting has to go the other way round.
                """
            case .ambiguousLinkTarget(let name):
                """
                '\(name)' is both an installed skill and a group. Pass --as-group to link the \
                group, or rename one of the two.
                """
            }
        }
    }

    /// What `install` is busy with, so a caller can say so instead of going quiet for minutes.
    ///
    /// Cloning an aggregator repository takes long enough that silence reads as a hang, and the
    /// scan that follows is worse: it parses the front matter of every `SKILL.md` in the clone.
    public enum Progress: Sendable {
        case cloning(repo: String)
        case updating(repo: String)
        /// A line of git's own progress output, already stripped of its carriage return.
        case git(String)
        /// Falling back to walking the whole clone, because the identifier is not a path.
        case scanning(repo: String)
        case resolvingLicense(name: String)
    }

    public struct InstallOutcome: Sendable {
        public var name: String
        public var skill: DiscoveredSkill
        public var ref: SkillRef
        public var commit: String
        public var group: String?
        /// True when the lock already had this skill at this commit and nothing was fetched.
        public var wasUpToDate: Bool
    }

    // MARK: - Install

    /// Installs one skill, or every skill in the repository when `ref.skillID` is `nil`.
    public mutating func install(
        ref: SkillRef,
        as explicitName: String? = nil,
        group: String? = nil,
        forceUpdate: Bool = false,
        onProgress: (@Sendable (Progress) -> Void)? = nil
    ) async throws -> [InstallOutcome] {
        try await git.ensureAvailable()
        try workspace.layout.createDirectories()

        let repositoryDirectory = workspace.layout.repositoryDirectory(for: ref)
        let alreadyCloned = git.isRepository(repositoryDirectory)
        // Written out rather than with `map`: the type checker cannot see through an optional
        // closure returning a `@Sendable` one.
        let gitProgress: (@Sendable (String) -> Void)?
        if let onProgress {
            gitProgress = { line in onProgress(.git(line)) }
        } else {
            gitProgress = nil
        }

        if !alreadyCloned {
            guard let cloneURL = ref.cloneURL else {
                throw InstallError.noSkillsInRepository(ref.repoSlug)
            }
            onProgress?(.cloning(repo: ref.repoSlug))
            try await git.clone(
                from: cloneURL,
                into: repositoryDirectory,
                ref: ref.gitRef,
                depth: workspace.config.cloneDepth,
                onProgress: gitProgress
            )
        } else if forceUpdate {
            onProgress?(.updating(repo: ref.repoSlug))
            try await git.update(
                directory: repositoryDirectory,
                ref: ref.gitRef,
                depth: workspace.config.cloneDepth,
                onProgress: gitProgress
            )
        }

        let commit = try await git.headCommit(in: repositoryDirectory)

        // A skill identified by its path needs no scan at all. That matters: on an aggregator
        // repository the scan parses the front matter of every SKILL.md in the clone, of which
        // there can be hundreds of thousands.
        if let skillID = ref.skillID,
           let direct = SkillDiscovery.skill(at: skillID, in: repositoryDirectory) {
            return try finishInstall(
                targets: [direct],
                ref: ref,
                explicitName: explicitName,
                group: group,
                commit: commit,
                repositoryDirectory: repositoryDirectory,
                alreadyCloned: alreadyCloned,
                onProgress: onProgress
            )
        }

        onProgress?(.scanning(repo: ref.repoSlug))
        let discovered = SkillDiscovery.discoverSkills(in: repositoryDirectory)
        guard !discovered.isEmpty else { throw InstallError.noSkillsInRepository(ref.repoSlug) }

        let targets: [DiscoveredSkill]
        if let skillID = ref.skillID {
            targets = [try SkillDiscovery.resolve(identifier: skillID, in: discovered, repoSlug: ref.repoSlug)]
        } else if discovered.count == 1 {
            targets = discovered
        } else if explicitName != nil {
            // An explicit name only makes sense for a single skill.
            throw SkillDiscovery.ResolutionError(
                identifier: nil,
                candidates: discovered.map { $0.relativePath.isEmpty ? "." : $0.relativePath },
                repoSlug: ref.repoSlug
            )
        } else {
            targets = discovered
        }

        return try finishInstall(
            targets: targets,
            ref: ref,
            explicitName: explicitName,
            group: group,
            commit: commit,
            repositoryDirectory: repositoryDirectory,
            alreadyCloned: alreadyCloned,
            onProgress: onProgress
        )
    }

    /// Links the resolved skills into the workspace and records them, whichever way they were
    /// found. Shared by the path fast path and the full scan so both write the lock identically.
    private mutating func finishInstall(
        targets: [DiscoveredSkill],
        ref: SkillRef,
        explicitName: String?,
        group: String?,
        commit: String,
        repositoryDirectory: URL,
        alreadyCloned: Bool,
        onProgress: (@Sendable (Progress) -> Void)?
    ) throws -> [InstallOutcome] {
        var outcomes: [InstallOutcome] = []
        var updatedLock = workspace.lock

        for skill in targets {
            let name = explicitName ?? defaultName(for: skill, ref: ref)
            let resolvedRef = SkillRef(
                host: ref.host,
                owner: ref.owner,
                repo: ref.repo,
                skillID: skill.relativePath.isEmpty ? nil : skill.relativePath,
                gitRef: ref.gitRef
            )

            if let existing = updatedLock[name], !existing.matches(resolvedRef) {
                throw InstallError.nameTaken(
                    name: name,
                    existing: "\(existing.repoSlug)/\(existing.skillPath)",
                    incoming: resolvedRef.canonical
                )
            }

            let wasUpToDate = updatedLock[name]?.commit == commit

            let target = workspace.layout.skillDirectory(
                host: ref.host,
                owner: ref.owner,
                repo: ref.repo,
                skillPath: skill.relativePath
            )
            try LinkManager.createLink(
                at: workspace.layout.installLink(name: name),
                to: target,
                replaceExisting: true
            )

            var groups = updatedLock[name]?.groups ?? []
            if let group {
                try LinkManager.createLink(
                    at: workspace.layout.groupLink(group: group, name: name),
                    to: workspace.layout.installLink(name: name),
                    replaceExisting: true
                )
                if !groups.contains(group) { groups.append(group) }
            }

            onProgress?(.resolvingLicense(name: name))
            let license = LicenseResolver.resolve(
                manifest: skill.manifest,
                registry: registry.lookup(repo: ref.repoSlug, skillName: name),
                repositoryDirectory: repositoryDirectory
            )

            updatedLock.upsert(
                LockedSkill(
                    name: name,
                    origin: .git,
                    host: ref.host,
                    owner: ref.owner,
                    repo: ref.repo,
                    skillPath: skill.relativePath,
                    gitRef: ref.gitRef,
                    commit: commit,
                    groups: groups,
                    installedAt: updatedLock[name]?.installedAt ?? Date(),
                    license: license.license,
                    licenseSource: license.source,
                    distribution: license.distribution,
                    licenseFile: license.licenseFile
                )
            )

            outcomes.append(
                InstallOutcome(
                    name: name,
                    skill: skill,
                    ref: resolvedRef,
                    commit: commit,
                    group: group,
                    wasUpToDate: wasUpToDate && alreadyCloned
                )
            )
        }

        try workspace.updateLock { $0 = updatedLock }
        return outcomes
    }

    // MARK: - Groups

    public mutating func link(name: String, into group: String) throws {
        guard workspace.lock[name] != nil || installExists(name) else {
            throw InstallError.notInstalled(name: name)
        }
        try LinkManager.createLink(
            at: workspace.layout.groupLink(group: group, name: name),
            to: workspace.layout.installLink(name: name),
            replaceExisting: true
        )
        try workspace.updateLock { lock in
            guard var entry = lock[name] else { return }
            if !entry.groups.contains(group) {
                entry.groups = (entry.groups + [group]).sorted()
                lock.upsert(entry)
            }
        }
    }

    public mutating func unlink(name: String, from group: String) throws {
        let link = workspace.layout.groupLink(group: group, name: name)
        // Whether this was a skill link decides whether the lock has anything to say about it.
        // A group link named after an installed skill must not strip that skill's membership.
        let wasSkillLink = LinkManager.resolvedDestination(of: link).map {
            LinkManager.samePath($0, workspace.layout.installLink(name: name))
        } ?? false

        try LinkManager.removeLink(at: link)
        guard wasSkillLink else { return }
        try workspace.updateLock { lock in
            guard var entry = lock[name] else { return }
            entry.groups.removeAll { $0 == group }
            lock.upsert(entry)
        }
    }

    /// Links one group into another, so `skills/ios` can gather `skills/swift` and
    /// `skills/swiftui` without duplicating their members.
    ///
    /// Unlike a skill link this is not recorded in the lock file: `skills/` is the user's to
    /// arrange, and only skill membership is something `sync` can meaningfully rebuild.
    /// The link takes the target's last path component as its name, so
    /// `link ios vpbank/bkt` yields `skills/ios/bkt`.
    ///
    /// - Returns: the name the link was created under.
    @discardableResult
    public func linkGroup(_ target: String, into group: String) throws -> String {
        let skillsRoot = workspace.layout.skillsDirectory
        let targetDirectory = workspace.layout.groupDirectory(GroupResolver.normalize(target))
        guard Workspace.isDirectory(targetDirectory) else {
            throw InstallError.noSuchGroup(GroupResolver.normalize(target))
        }

        let normalizedTarget = LinkManager.relativePath(from: skillsRoot, to: targetDirectory)
        let destination = workspace.layout.groupDirectory(GroupResolver.normalize(group))
        let normalizedGroup = LinkManager.relativePath(from: skillsRoot, to: destination)

        // A group linked into itself or into one of its own descendants is a filesystem loop,
        // not a cycle the resolver can report its way out of. Sibling cycles (a → b → a) are
        // left alone: they resolve fine, and `apply` reports them.
        let wouldNestInsideItself = normalizedGroup == normalizedTarget
            || normalizedGroup.hasPrefix(normalizedTarget + "/")
        guard !wouldNestInsideItself else {
            throw InstallError.groupContainsItself(group: normalizedGroup, target: normalizedTarget)
        }

        let name = targetDirectory.lastPathComponent
        try LinkManager.createLink(
            at: workspace.layout.groupLink(group: normalizedGroup, name: name),
            to: targetDirectory,
            replaceExisting: true
        )
        return name
    }

    /// Whether a name refers to a group under `skills/`.
    public func isGroup(_ name: String) -> Bool {
        let directory = workspace.layout.groupDirectory(GroupResolver.normalize(name))
        return Workspace.isDirectory(directory)
    }

    /// Whether a name refers to something under `installs/`.
    public func isInstalled(_ name: String) -> Bool {
        workspace.lock[name] != nil || installExists(name)
            || Workspace.isDirectory(workspace.layout.installLink(name: name))
    }

    // MARK: - Removal

    public struct RemovalOutcome: Sendable {
        public var name: String
        public var removedGroups: [String]
        public var prunedRepository: String?
    }

    /// Removes the install link and every group link. With `prune`, also deletes the clone
    /// once no other install still points into it.
    ///
    /// An adopted (`.local`) skill *is* its content — there is no clone to fall back on — so
    /// removing one requires `prune` to make the data loss explicit.
    public mutating func remove(name: String, prune: Bool = false) throws -> RemovalOutcome {
        let entry = workspace.lock[name]
        let installLink = workspace.layout.installLink(name: name)
        guard entry != nil || installExists(name) || Workspace.isDirectory(installLink) else {
            throw InstallError.notInstalled(name: name)
        }

        let isLocalContent = entry?.origin == .local || (!installExists(name) && Workspace.isDirectory(installLink))
        if isLocalContent, !prune {
            throw InstallError.localRequiresPrune(name: name)
        }

        // Trust the filesystem over the lock file: a link made by hand still gets cleaned up.
        let groups = Set((entry?.groups ?? []) + workspace.groupsContaining(name: name)).sorted()
        for group in groups {
            try? LinkManager.removeLink(at: workspace.layout.groupLink(group: group, name: name))
        }

        if isLocalContent {
            try FileManager.default.removeItem(at: installLink)
        } else {
            try? LinkManager.removeLink(at: installLink)
        }

        var pruned: String?
        try workspace.updateLock { lock in
            lock.remove(name: name)
        }

        if prune, let entry, entry.origin == .git {
            let key = "\(entry.host)/\(entry.owner)/\(entry.repo)"
            if !workspace.lock.referencedRepos.contains(key) {
                let directory = workspace.layout.repositoryDirectory(for: entry)
                try? FileManager.default.removeItem(at: directory)
                // Leave no empty <host>/<owner> shells behind.
                removeEmptyParents(of: directory, stoppingAt: workspace.layout.downloadsDirectory)
                pruned = entry.repoSlug
            }
        }

        return RemovalOutcome(name: name, removedGroups: groups, prunedRepository: pruned)
    }

    // MARK: - Sync

    public struct SyncReport: Sendable {
        public var cloned: [String] = []
        /// `name: <old short sha> → <new short sha>`
        public var updated: [String] = []
        public var relinked: [String] = []
        /// Licence information that was missing or has changed.
        public var relicensed: [String] = []
        public var unchanged: [String] = []
        public var failures: [String] = []

        public var madeChanges: Bool {
            !cloned.isEmpty || !updated.isEmpty || !relinked.isEmpty || !relicensed.isEmpty
        }
    }

    /// Brings the filesystem back in line with the lock file.
    ///
    /// Without `update` this is reproduction: missing clones are fetched and checked out at
    /// the locked commit, and links are repaired. With `update` each skill is moved to the tip
    /// of its ref and the lock is rewritten.
    public mutating func sync(update: Bool = false) async throws -> SyncReport {
        try await git.ensureAvailable()
        try workspace.layout.createDirectories()

        var report = SyncReport()
        var updatedLock = workspace.lock

        for entry in workspace.lock.skills {
            do {
                var entry = entry

                if entry.origin == .git {
                    let repositoryDirectory = workspace.layout.repositoryDirectory(for: entry)

                    if !git.isRepository(repositoryDirectory) {
                        guard let cloneURL = entry.ref.cloneURL else {
                            throw InstallError.noSkillsInRepository(entry.repoSlug)
                        }
                        try await git.clone(
                            from: cloneURL,
                            into: repositoryDirectory,
                            ref: entry.gitRef,
                            depth: workspace.config.cloneDepth
                        )
                        report.cloned.append("\(entry.name) ← \(entry.repoSlug)")
                        if !update, !entry.commit.isEmpty {
                            let restored = await git.ensureCommit(entry.commit, in: repositoryDirectory)
                            if !restored {
                                report.failures.append(
                                    "\(entry.name): commit \(git.shortCommit(entry.commit)) is unreachable — using \(entry.gitRef ?? "the default branch") instead"
                                )
                                entry.commit = try await git.headCommit(in: repositoryDirectory)
                            }
                        }
                    }

                    if update {
                        if await git.hasLocalChanges(in: repositoryDirectory) {
                            report.failures.append(
                                "\(entry.name): \(entry.repoSlug) has uncommitted changes — skipped"
                            )
                        } else {
                            let before = try await git.headCommit(in: repositoryDirectory)
                            try await git.update(
                                directory: repositoryDirectory,
                                ref: entry.gitRef,
                                depth: workspace.config.cloneDepth
                            )
                            let after = try await git.headCommit(in: repositoryDirectory)
                            entry.commit = after
                            if before != after {
                                report.updated.append(
                                    "\(entry.name): \(git.shortCommit(before)) → \(git.shortCommit(after))"
                                )
                            } else {
                                report.unchanged.append(entry.name)
                            }
                        }
                    }

                    let skillDirectory = workspace.layout.skillDirectory(for: entry)
                    guard Workspace.isDirectory(skillDirectory) else {
                        report.failures.append(
                            "\(entry.name): '\(entry.skillPath)' is missing from \(entry.repoSlug) at this commit"
                        )
                        continue
                    }

                    let installLink = workspace.layout.installLink(name: entry.name)
                    if LinkManager.state(of: installLink, expectedTarget: skillDirectory) != .correct {
                        try LinkManager.createLink(at: installLink, to: skillDirectory, replaceExisting: true)
                        report.relinked.append("installs/\(entry.name)")
                    }

                    // Re-resolve every time: it backfills entries locked before licences were
                    // recorded, and picks up an upstream relicence on --update.
                    let manifestURL = skillDirectory
                        .appending(path: SkillManifest.fileName, directoryHint: .notDirectory)
                    let manifest = FileManager.default.fileExists(
                        atPath: manifestURL.path(percentEncoded: false)
                    ) ? FrontmatterParser.parse(fileAt: manifestURL, fallbackName: entry.name) : nil

                    let license = LicenseResolver.resolve(
                        manifest: manifest,
                        registry: registry.lookup(repo: entry.repoSlug, skillName: entry.name),
                        repositoryDirectory: repositoryDirectory
                    )
                    if entry.license != license.license || entry.distribution != license.distribution {
                        report.relicensed.append(
                            "\(entry.name): \(entry.license ?? "—") → \(license.license ?? "—")"
                        )
                    }
                    entry.license = license.license
                    entry.licenseSource = license.source
                    entry.distribution = license.distribution
                    entry.licenseFile = license.licenseFile
                } else {
                    // Adopted skills have no clone, but their own SKILL.md and any licence
                    // file that travelled with them still count — and entries adopted before
                    // licences were recorded would otherwise stay blank forever.
                    let installDirectory = workspace.layout.installLink(name: entry.name)
                    let manifestURL = installDirectory
                        .appending(path: SkillManifest.fileName, directoryHint: .notDirectory)
                    let manifest = FileManager.default.fileExists(
                        atPath: manifestURL.path(percentEncoded: false)
                    ) ? FrontmatterParser.parse(fileAt: manifestURL, fallbackName: entry.name) : nil

                    let license = LicenseResolver.resolve(
                        manifest: manifest,
                        registry: nil,
                        repositoryDirectory: installDirectory
                    )
                    if entry.license != license.license {
                        report.relicensed.append(
                            "\(entry.name): \(entry.license ?? "—") → \(license.license ?? "—")"
                        )
                    }
                    entry.license = license.license
                    entry.licenseSource = license.source
                    entry.licenseFile = license.licenseFile
                }

                // Group links apply to adopted skills too.
                let installLink = workspace.layout.installLink(name: entry.name)
                for group in entry.groups {
                    let groupLink = workspace.layout.groupLink(group: group, name: entry.name)
                    if LinkManager.state(of: groupLink, expectedTarget: installLink) != .correct {
                        try LinkManager.createLink(at: groupLink, to: installLink, replaceExisting: true)
                        report.relinked.append("skills/\(group)/\(entry.name)")
                    }
                }

                updatedLock.upsert(entry)
            } catch {
                report.failures.append("\(entry.name): \(error)")
            }
        }

        try workspace.updateLock { $0 = updatedLock }
        return report
    }

    // MARK: - Adoption

    public struct AdoptionOutcome: Sendable {
        public var name: String
        /// Where the directory used to live, relative to the workspace root.
        public var previousPath: String
        /// Group links recreated to point at the new install.
        public var groups: [String]
        public var manifest: SkillManifest
    }

    /// Turns a real directory under `skills/` into a managed install.
    ///
    /// The directory is *moved* to `installs/<name>` and the original location becomes a
    /// symlink, so the grouping the user already built keeps working. Content is never copied
    /// or rewritten — an adopted skill has no upstream, so nothing can be re-fetched.
    public mutating func adopt(directory: URL, as explicitName: String? = nil) throws -> AdoptionOutcome {
        let fileManager = FileManager.default
        let source = directory.standardizedFileURL

        guard Workspace.isDirectory(source), !LinkManager.isSymlink(source) else {
            throw InstallError.notAdoptable(path: source.path(percentEncoded: false), reason: "not a real directory")
        }
        let manifestURL = source.appending(path: SkillManifest.fileName, directoryHint: .notDirectory)
        guard fileManager.fileExists(atPath: manifestURL.path(percentEncoded: false)) else {
            throw InstallError.notAdoptable(
                path: source.path(percentEncoded: false),
                reason: "no \(SkillManifest.fileName)"
            )
        }

        let name = explicitName ?? source.lastPathComponent
        let installLink = workspace.layout.installLink(name: name)
        guard !fileManager.fileExists(atPath: installLink.path(percentEncoded: false)) else {
            throw InstallError.nameTaken(
                name: name,
                existing: workspace.lock[name]?.sourceDescription ?? "installs/\(name)",
                incoming: source.path(percentEncoded: false)
            )
        }

        let manifest = FrontmatterParser.parse(fileAt: manifestURL, fallbackName: name)
        let previousPath = LinkManager.relativePath(from: workspace.root, to: source)
        // Only meaningful when the directory sits under skills/<group>/.
        let group = groupName(for: source)

        try workspace.layout.createDirectories()
        try fileManager.moveItem(at: source, to: installLink)

        var groups: [String] = []
        if let group {
            try LinkManager.createLink(at: source, to: installLink, replaceExisting: true)
            groups.append(group)
        }

        // An adopted skill has no repository, so only what it declares about itself counts.
        let license = LicenseResolver.resolve(manifest: manifest, registry: nil, repositoryDirectory: installLink)
        try workspace.updateLock { lock in
            lock.upsert(
                LockedSkill(
                    name: name,
                    origin: .local,
                    groups: groups,
                    license: license.license,
                    licenseSource: license.source,
                    distribution: license.distribution,
                    licenseFile: license.licenseFile
                )
            )
        }

        return AdoptionOutcome(
            name: name,
            previousPath: previousPath,
            groups: groups,
            manifest: manifest
        )
    }

    /// Real (non-symlink) directories under `skills/` that hold a `SKILL.md`.
    public func adoptionCandidates() -> [URL] {
        var found: [URL] = []
        let skillsRoot = workspace.layout.skillsDirectory
        guard let enumerator = FileManager.default.enumerator(
            at: skillsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        for case let url as URL in enumerator {
            guard url.lastPathComponent.caseInsensitiveCompare(SkillManifest.fileName) == .orderedSame
            else { continue }
            let directory = url.deletingLastPathComponent()
            guard !LinkManager.isSymlink(directory), directory != skillsRoot else { continue }
            found.append(directory)
        }
        return found.sorted { $0.path < $1.path }
    }

    /// The group a path under `skills/` belongs to, i.e. everything between `skills/` and the
    /// skill directory itself. `nil` when the path is not under `skills/`.
    private func groupName(for directory: URL) -> String? {
        let relative = LinkManager.relativePath(from: workspace.layout.skillsDirectory, to: directory)
        guard !relative.hasPrefix(".."), relative != "." else { return nil }
        var components = relative.split(separator: "/").map(String.init)
        guard components.count >= 2 else { return nil }
        components.removeLast()
        return components.joined(separator: "/")
    }

    // MARK: - Helpers

    /// Walks up from `directory`, deleting directories that are now empty, and stops before
    /// touching `boundary`.
    private func removeEmptyParents(of directory: URL, stoppingAt boundary: URL) {
        let fileManager = FileManager.default
        var current = directory.deletingLastPathComponent().standardizedFileURL
        let stop = boundary.standardizedFileURL

        while current != stop, current.pathComponents.count > stop.pathComponents.count {
            let contents = (try? fileManager.contentsOfDirectory(
                at: current,
                includingPropertiesForKeys: nil,
                options: []
            )) ?? []
            // .DS_Store and friends should not keep an otherwise dead directory alive.
            let meaningful = contents.filter { !$0.lastPathComponent.hasPrefix(".") }
            guard meaningful.isEmpty else { return }
            try? fileManager.removeItem(at: current)
            current = current.deletingLastPathComponent().standardizedFileURL
        }
    }

    private func installExists(_ name: String) -> Bool {
        LinkManager.isSymlink(workspace.layout.installLink(name: name))
    }

    /// Skill directory name, or the repository name when the `SKILL.md` sits at the root.
    private func defaultName(for skill: DiscoveredSkill, ref: SkillRef) -> String {
        skill.relativePath.isEmpty ? ref.repo : skill.directoryName
    }
}

extension LockedSkill {
    /// Whether this entry describes the same skill in the same repository.
    func matches(_ ref: SkillRef) -> Bool {
        host == ref.host
            && owner == ref.owner
            && repo == ref.repo
            && skillPath == (ref.skillID ?? "")
    }
}
