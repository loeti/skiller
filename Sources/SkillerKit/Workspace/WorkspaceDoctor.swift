import Foundation

/// Read-only consistency check across the lock file and the three directories.
///
/// `doctor` only reports; `sync` is what repairs. Keeping them apart means running a
/// diagnosis is always safe.
public enum WorkspaceDoctor {
    public struct Issue: Sendable, Equatable {
        public enum Kind: String, Sendable {
            case missingClone
            case missingSkillDirectory
            case missingInstallLink
            case wrongInstallLink
            case brokenInstallLink
            case untrackedInstall
            case missingGroupLink
            case brokenGroupLink
            case unreferencedDownload
            case unadoptedDirectory
        }

        public var kind: Kind
        /// Workspace-relative path the issue is about.
        public var path: String
        public var detail: String
        public var fix: String
        /// `true` when `sync` can repair it without asking.
        public var isRepairableBySync: Bool
    }

    public static func diagnose(_ workspace: Workspace) -> [Issue] {
        var issues: [Issue] = []
        let layout = workspace.layout
        let fileManager = FileManager.default

        // 1. Everything the lock claims should exist.
        for entry in workspace.lock.skills {
            let installLink = layout.installLink(name: entry.name)
            let installPath = relative(installLink, in: workspace)

            if entry.origin == .git {
                let repositoryDirectory = layout.repositoryDirectory(for: entry)
                guard Workspace.isDirectory(repositoryDirectory) else {
                    issues.append(
                        Issue(
                            kind: .missingClone,
                            path: relative(repositoryDirectory, in: workspace),
                            detail: "\(entry.sourceDescription) is in the lock file but not cloned",
                            fix: "skiller sync",
                            isRepairableBySync: true
                        )
                    )
                    continue
                }

                let skillDirectory = layout.skillDirectory(for: entry)
                guard Workspace.isDirectory(skillDirectory) else {
                    issues.append(
                        Issue(
                            kind: .missingSkillDirectory,
                            path: relative(skillDirectory, in: workspace),
                            detail: "'\(entry.skillPath)' no longer exists in \(entry.repoSlug) at \(String(entry.commit.prefix(7)))",
                            fix: "skiller remove \(entry.name), or re-add at a different ref",
                            isRepairableBySync: false
                        )
                    )
                    continue
                }

                switch LinkManager.state(of: installLink, expectedTarget: skillDirectory) {
                case .correct:
                    break
                case .missing:
                    issues.append(Issue(
                        kind: .missingInstallLink,
                        path: installPath,
                        detail: "no link for '\(entry.name)'",
                        fix: "skiller sync",
                        isRepairableBySync: true
                    ))
                case .wrongTarget(let actual):
                    issues.append(Issue(
                        kind: .wrongInstallLink,
                        path: installPath,
                        detail: "points at '\(actual)' instead of the locked skill",
                        fix: "skiller sync",
                        isRepairableBySync: true
                    ))
                case .broken(let target):
                    issues.append(Issue(
                        kind: .brokenInstallLink,
                        path: installPath,
                        detail: "dangling link to '\(target)'",
                        fix: "skiller sync",
                        isRepairableBySync: true
                    ))
                case .occupiedByRealPath:
                    issues.append(Issue(
                        kind: .wrongInstallLink,
                        path: installPath,
                        detail: "a real directory sits where the link belongs",
                        fix: "move it aside, then skiller sync",
                        isRepairableBySync: false
                    ))
                }
            } else {
                // Adopted skills hold their own content.
                if !Workspace.isDirectory(installLink) || LinkManager.isSymlink(installLink) {
                    issues.append(Issue(
                        kind: .missingInstallLink,
                        path: installPath,
                        detail: "adopted skill '\(entry.name)' has no content directory",
                        fix: "skiller remove \(entry.name) --prune",
                        isRepairableBySync: false
                    ))
                }
            }

            // 2. Group links the lock records.
            for group in entry.groups {
                let groupLink = layout.groupLink(group: group, name: entry.name)
                switch LinkManager.state(of: groupLink, expectedTarget: installLink) {
                case .correct:
                    break
                case .missing:
                    issues.append(Issue(
                        kind: .missingGroupLink,
                        path: relative(groupLink, in: workspace),
                        detail: "'\(entry.name)' should be linked into '\(group)'",
                        fix: "skiller sync",
                        isRepairableBySync: true
                    ))
                case .broken(let target):
                    issues.append(Issue(
                        kind: .brokenGroupLink,
                        path: relative(groupLink, in: workspace),
                        detail: "dangling link to '\(target)'",
                        fix: "skiller sync",
                        isRepairableBySync: true
                    ))
                case .wrongTarget(let actual):
                    issues.append(Issue(
                        kind: .brokenGroupLink,
                        path: relative(groupLink, in: workspace),
                        detail: "points at '\(actual)' instead of installs/\(entry.name)",
                        fix: "skiller sync",
                        isRepairableBySync: true
                    ))
                case .occupiedByRealPath:
                    issues.append(Issue(
                        kind: .unadoptedDirectory,
                        path: relative(groupLink, in: workspace),
                        detail: "real directory where a group link belongs",
                        fix: "skiller adopt \(relative(groupLink, in: workspace))",
                        isRepairableBySync: false
                    ))
                }
            }
        }

        // 3. Installs nobody tracks.
        let tracked = Set(workspace.lock.skills.map(\.name))
        for name in workspace.installedNames() where !tracked.contains(name) {
            issues.append(Issue(
                kind: .untrackedInstall,
                path: relative(layout.installLink(name: name), in: workspace),
                detail: "'\(name)' exists but is not in the lock file",
                fix: "skiller remove \(name), or re-add it to record where it came from",
                isRepairableBySync: false
            ))
        }

        // 4. Group links pointing nowhere useful.
        for group in workspace.groups() {
            for link in LinkManager.symlinks(in: layout.groupDirectory(group)) {
                let name = link.lastPathComponent
                let expected = layout.installLink(name: name)
                if case .correct = LinkManager.state(of: link, expectedTarget: expected) { continue }
                // A link into skills/ is a subgroup, not a skill that lost its install.
                if let destination = LinkManager.resolvedDestination(of: link),
                   Workspace.isDirectory(destination),
                   GroupResolver.isUnder(destination, root: layout.skillsDirectory) {
                    continue
                }
                guard workspace.lock[name]?.groups.contains(group) != true else { continue }
                issues.append(Issue(
                    kind: .brokenGroupLink,
                    path: relative(link, in: workspace),
                    detail: "does not resolve to installs/\(name)",
                    fix: "skiller unlink \(group) \(name)",
                    isRepairableBySync: false
                ))
            }
        }

        // 5. Clones nothing points at any more.
        let referenced = workspace.lock.referencedRepos
        for repository in clonedRepositories(in: workspace) where !referenced.contains(repository.key) {
            issues.append(Issue(
                kind: .unreferencedDownload,
                path: relative(repository.url, in: workspace),
                detail: "clone is no longer referenced by any install",
                fix: "delete it, or re-add a skill from it",
                isRepairableBySync: false
            ))
        }

        // 6. Real directories that should become installs.
        let installer = SkillInstaller(workspace: workspace)
        for candidate in installer.adoptionCandidates() {
            issues.append(Issue(
                kind: .unadoptedDirectory,
                path: relative(candidate, in: workspace),
                detail: "real skill directory under skills/ — not linked, not tracked",
                fix: "skiller adopt \(relative(candidate, in: workspace))",
                isRepairableBySync: false
            ))
        }

        _ = fileManager
        return issues
    }

    /// `<host>/<owner>/<repo>` directories under `downloads/`, with the key used by the lock.
    static func clonedRepositories(in workspace: Workspace) -> [(key: String, url: URL)] {
        let downloads = workspace.layout.downloadsDirectory
        var result: [(String, URL)] = []
        for host in subdirectories(of: downloads) {
            for owner in subdirectories(of: host) {
                for repo in subdirectories(of: owner) {
                    let key = "\(host.lastPathComponent)/\(owner.lastPathComponent)/\(repo.lastPathComponent)"
                    result.append((key, repo))
                }
            }
        }
        return result.sorted { $0.0 < $1.0 }
    }

    private static func subdirectories(of url: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents.filter { Workspace.isDirectory($0) && !LinkManager.isSymlink($0) }
    }

    /// Workspace-relative path for display.
    ///
    /// The directory *prefix* is canonicalised on both sides, because paths coming back from
    /// `FileManager` may spell a symlinked ancestor differently than `Layout` does and the
    /// subtraction would then produce a wall of `..`. The last component is appended
    /// afterwards, so a link is still reported by its own path rather than its target's.
    private static func relative(_ url: URL, in workspace: Workspace) -> String {
        let root = URL(filePath: LinkManager.canonicalPath(workspace.root), directoryHint: .isDirectory)
        let parent = URL(
            filePath: LinkManager.canonicalPath(url.deletingLastPathComponent()),
            directoryHint: .isDirectory
        )
        return LinkManager.relativePath(
            from: root,
            to: parent.appending(path: url.lastPathComponent, directoryHint: .notDirectory)
        )
    }
}
