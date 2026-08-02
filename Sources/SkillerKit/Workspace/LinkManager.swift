import Foundation

/// Creates and inspects the relative symlinks that hold the workspace together.
///
/// Links are always relative so the whole workspace can be moved or synced to another
/// machine without every link breaking.
public enum LinkManager {
    public enum LinkState: Sendable, Equatable {
        /// Nothing exists at the link path.
        case missing
        /// A symlink pointing at the expected target.
        case correct
        /// A symlink pointing somewhere else.
        case wrongTarget(actual: String)
        /// A symlink whose target does not exist.
        case broken(target: String)
        /// A real file or directory sitting where a symlink belongs.
        case occupiedByRealPath
    }

    public struct LinkError: Error, CustomStringConvertible {
        public var path: String
        public var reason: String
        public var description: String { "\(path): \(reason)" }
    }

    /// Lexical relative path from a directory to a target. Purely textual — it does not
    /// resolve symlinks, which is what we want, since both paths are inside the workspace.
    public static func relativePath(from directory: URL, to target: URL) -> String {
        let base = directory.standardizedFileURL.pathComponents
        let destination = target.standardizedFileURL.pathComponents

        var shared = 0
        while shared < base.count, shared < destination.count, base[shared] == destination[shared] {
            shared += 1
        }

        let ascend = Array(repeating: "..", count: base.count - shared)
        let descend = Array(destination[shared...])
        let components = ascend + descend
        return components.isEmpty ? "." : components.joined(separator: "/")
    }

    public static func state(of link: URL, expectedTarget: URL) -> LinkState {
        let fileManager = FileManager.default
        let path = filesystemPath(link)

        guard let attributes = try? fileManager.attributesOfItem(atPath: path) else {
            // attributesOfItem does not follow symlinks, so a failure means nothing is there.
            return .missing
        }
        guard attributes[.type] as? FileAttributeType == .typeSymbolicLink else {
            return .occupiedByRealPath
        }
        guard let destination = try? fileManager.destinationOfSymbolicLink(atPath: path) else {
            return .broken(target: "<unreadable>")
        }

        let expected = relativePath(from: link.deletingLastPathComponent(), to: expectedTarget)
        let resolved = URL(
            filePath: destination,
            directoryHint: .isDirectory,
            relativeTo: link.deletingLastPathComponent()
        ).standardizedFileURL

        if destination != expected {
            // Compare resolved paths too: an absolute link to the right place is still wrong
            // for our purposes, but reporting the actual target is more useful than "broken".
            return .wrongTarget(actual: destination)
        }
        guard fileManager.fileExists(atPath: resolved.path(percentEncoded: false)) else {
            return .broken(target: destination)
        }
        return .correct
    }

    /// Points `link` at `target` using a relative path.
    ///
    /// - Parameter replaceExisting: replaces an existing *symlink*. A real file or directory
    ///   is never removed silently — that always throws.
    public static func createLink(at link: URL, to target: URL, replaceExisting: Bool = false) throws {
        let fileManager = FileManager.default
        let path = filesystemPath(link)

        switch state(of: link, expectedTarget: target) {
        case .correct:
            return
        case .occupiedByRealPath:
            throw LinkError(
                path: path,
                reason: "a real file or directory is already there — move or remove it first, or use `adopt`"
            )
        case .wrongTarget(let actual):
            guard replaceExisting else {
                throw LinkError(path: path, reason: "already links to '\(actual)'")
            }
            try fileManager.removeItem(at: link)
        case .broken:
            try fileManager.removeItem(at: link)
        case .missing:
            break
        }

        try fileManager.createDirectory(
            at: link.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let relative = relativePath(from: link.deletingLastPathComponent(), to: target)
        try fileManager.createSymbolicLink(atPath: path, withDestinationPath: relative)
    }

    /// Removes a symlink. Refuses to touch real files or directories.
    public static func removeLink(at link: URL) throws {
        let fileManager = FileManager.default
        let path = filesystemPath(link)
        guard let attributes = try? fileManager.attributesOfItem(atPath: path) else { return }
        guard attributes[.type] as? FileAttributeType == .typeSymbolicLink else {
            throw LinkError(path: path, reason: "not a symlink — refusing to delete")
        }
        try fileManager.removeItem(at: link)
    }

    public static func isSymlink(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(
            atPath: filesystemPath(url)
        ) else { return false }
        return attributes[.type] as? FileAttributeType == .typeSymbolicLink
    }

    /// A path without a trailing slash.
    ///
    /// `URL.path` keeps the slash a directory hint added, and the POSIX layer then insists the
    /// path already be an existing directory — which breaks creating or stat-ing a symlink.
    static func filesystemPath(_ url: URL) -> String {
        let path = url.path(percentEncoded: false)
        guard path.count > 1, path.hasSuffix("/") else { return path }
        return String(path.dropLast())
    }

    /// Symlinks directly inside `directory`, sorted by name. Non-symlink entries are skipped.
    public static func symlinks(in directory: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents
            .filter(isSymlink)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
