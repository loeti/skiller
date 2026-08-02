import Foundation

/// A resolved workspace: its layout plus the persisted config and lock file.
public struct Workspace: Sendable {
    public static let environmentVariable = "AGENTIC_WORKSPACE"

    public let layout: Layout
    public private(set) var config: WorkspaceConfig
    public private(set) var lock: LockFile

    public var root: URL { layout.root }

    public init(root: URL) throws {
        self.layout = Layout(root: root)
        var config = try WorkspaceConfig.read(from: layout.configFile)
        // Persist the upgrade so the file on disk stops lagging behind what we actually use.
        // A read-only workspace still works — it just migrates again next time.
        if config.migrate() {
            try? config.write(to: layout.configFile)
        }
        self.config = config
        self.lock = try LockFile.read(from: layout.lockFile)
    }

    // MARK: - Discovery

    public enum ResolutionError: Error, CustomStringConvertible {
        case notFound(searchedFrom: String)
        case notADirectory(String)

        public var description: String {
            switch self {
            case .notFound(let from):
                """
                No workspace found. Searched upwards from '\(from)' for a '\(Layout.stateDirectoryName)' \
                directory.

                Pass --workspace <path>, set \(Workspace.environmentVariable), or run \
                `skiller init <path>` to create one.
                """
            case .notADirectory(let path):
                "'\(path)' is not a directory."
            }
        }
    }

    /// Resolves a workspace root: explicit path, then `AGENTIC_WORKSPACE`, then the nearest
    /// ancestor of the current directory containing `.skiller`.
    public static func resolveRoot(
        explicit: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentDirectory: URL = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    ) throws -> URL {
        if let explicit {
            let url = URL(filePath: explicit, directoryHint: .isDirectory).standardizedFileURL
            guard isDirectory(url) else { throw ResolutionError.notADirectory(explicit) }
            return url
        }
        if let fromEnvironment = environment[environmentVariable], !fromEnvironment.isEmpty {
            let url = URL(filePath: fromEnvironment, directoryHint: .isDirectory).standardizedFileURL
            guard isDirectory(url) else { throw ResolutionError.notADirectory(fromEnvironment) }
            return url
        }

        var candidate = currentDirectory.standardizedFileURL
        while true {
            let marker = candidate.appending(path: Layout.stateDirectoryName, directoryHint: .isDirectory)
            if isDirectory(marker) { return candidate }
            let parent = candidate.deletingLastPathComponent().standardizedFileURL
            if parent == candidate { break }
            candidate = parent
        }
        throw ResolutionError.notFound(searchedFrom: currentDirectory.path(percentEncoded: false))
    }

    public static func resolve(
        explicit: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> Workspace {
        try Workspace(root: try resolveRoot(explicit: explicit, environment: environment))
    }

    /// Creates the directory skeleton and writes a default config if none exists.
    @discardableResult
    public static func create(at root: URL) throws -> Workspace {
        let layout = Layout(root: root.standardizedFileURL)
        try layout.createDirectories()
        if !FileManager.default.fileExists(atPath: layout.configFile.path(percentEncoded: false)) {
            try WorkspaceConfig().write(to: layout.configFile)
        }
        if !FileManager.default.fileExists(atPath: layout.lockFile.path(percentEncoded: false)) {
            try LockFile().write(to: layout.lockFile)
        }
        return try Workspace(root: layout.root)
    }

    // MARK: - Persistence

    public mutating func updateLock(_ mutate: (inout LockFile) -> Void) throws {
        mutate(&lock)
        try lock.write(to: layout.lockFile)
    }

    public mutating func saveConfig(_ newValue: WorkspaceConfig) throws {
        config = newValue
        try config.write(to: layout.configFile)
    }

    public mutating func reload() throws {
        config = try WorkspaceConfig.read(from: layout.configFile)
        lock = try LockFile.read(from: layout.lockFile)
    }

    // MARK: - Queries

    /// Group directories under `skills/`, sorted. Nested groups are reported with their
    /// full relative path (`vpbank/bkt`), matching how they are addressed on the CLI.
    public func groups() -> [String] {
        var found: Set<String> = []
        let skillsRoot = layout.skillsDirectory
        guard let enumerator = FileManager.default.enumerator(
            at: skillsRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return [] }

        for case let url as URL in enumerator {
            guard !LinkManager.isSymlink(url), Self.isDirectory(url) else { continue }
            let relative = LinkManager.relativePath(from: skillsRoot, to: url)
            found.insert(relative)
            for nested in nestedGroups(under: url, skillsRoot: skillsRoot) {
                found.insert(nested)
            }
        }
        return found.sorted()
    }

    /// Groups a given install is linked into.
    public func groupsContaining(name: String) -> [String] {
        groups().filter { group in
            let link = layout.groupLink(group: group, name: name)
            return LinkManager.isSymlink(link)
        }.sorted()
    }

    /// Install names present under `installs/`, whether or not they are in the lock file.
    public func installedNames() -> [String] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: layout.installsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents.map(\.lastPathComponent).sorted()
    }

    private func nestedGroups(under directory: URL, skillsRoot: URL) -> [String] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        var result: [String] = []
        for url in contents where !LinkManager.isSymlink(url) && Self.isDirectory(url) {
            result.append(LinkManager.relativePath(from: skillsRoot, to: url))
            result.append(contentsOf: nestedGroups(under: url, skillsRoot: skillsRoot))
        }
        return result
    }

    static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: url.path(percentEncoded: false),
            isDirectory: &isDirectory
        )
        return exists && isDirectory.boolValue
    }
}
