import Foundation

/// Where everything lives inside a workspace.
///
/// ```
/// <root>/
/// ├── .skilltool/{config.json,lock.json}
/// ├── downloads/<host>/<owner>/<repo>/    git clone
/// ├── installs/<name>                     symlink → downloads/.../<skill path>
/// └── skills/<group>/<name>               symlink → installs/<name>
/// ```
public struct Layout: Sendable, Hashable {
    public static let stateDirectoryName = ".skilltool"
    public static let downloadsDirectoryName = "downloads"
    public static let installsDirectoryName = "installs"
    public static let skillsDirectoryName = "skills"

    public let root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    public var stateDirectory: URL { directory(Self.stateDirectoryName) }
    public var configFile: URL { stateDirectory.appending(path: "config.json", directoryHint: .notDirectory) }
    public var lockFile: URL { stateDirectory.appending(path: "lock.json", directoryHint: .notDirectory) }
    /// Last `search` result set, so `add <index>` can refer back to it.
    public var lastSearchFile: URL { stateDirectory.appending(path: "last-search.json", directoryHint: .notDirectory) }

    public var downloadsDirectory: URL { directory(Self.downloadsDirectoryName) }
    public var installsDirectory: URL { directory(Self.installsDirectoryName) }
    public var skillsDirectory: URL { directory(Self.skillsDirectoryName) }

    /// The clone location for a repository.
    public func repositoryDirectory(host: String, owner: String, repo: String) -> URL {
        downloadsDirectory
            .appending(path: host, directoryHint: .isDirectory)
            .appending(path: owner, directoryHint: .isDirectory)
            .appending(path: repo, directoryHint: .isDirectory)
    }

    public func repositoryDirectory(for ref: SkillRef) -> URL {
        repositoryDirectory(host: ref.host, owner: ref.owner, repo: ref.repo)
    }

    public func repositoryDirectory(for locked: LockedSkill) -> URL {
        repositoryDirectory(host: locked.host, owner: locked.owner, repo: locked.repo)
    }

    /// The directory a skill occupies inside its clone.
    public func skillDirectory(host: String, owner: String, repo: String, skillPath: String) -> URL {
        let base = repositoryDirectory(host: host, owner: owner, repo: repo)
        guard !skillPath.isEmpty else { return base }
        return base.appending(path: skillPath, directoryHint: .isDirectory)
    }

    public func skillDirectory(for locked: LockedSkill) -> URL {
        skillDirectory(
            host: locked.host,
            owner: locked.owner,
            repo: locked.repo,
            skillPath: locked.skillPath
        )
    }

    /// Symlink paths use `.notDirectory`: a trailing slash makes `createSymbolicLink` require
    /// an existing directory at that path, which is exactly what we are about to create.
    public func installLink(name: String) -> URL {
        installsDirectory.appending(path: name, directoryHint: .notDirectory)
    }

    public func groupDirectory(_ group: String) -> URL {
        skillsDirectory.appending(path: group, directoryHint: .isDirectory)
    }

    public func groupLink(group: String, name: String) -> URL {
        groupDirectory(group).appending(path: name, directoryHint: .notDirectory)
    }

    /// Creates the top-level directories. Safe to call repeatedly.
    public func createDirectories() throws {
        for url in [stateDirectory, downloadsDirectory, installsDirectory, skillsDirectory] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    private func directory(_ name: String) -> URL {
        root.appending(path: name, directoryHint: .isDirectory)
    }
}
