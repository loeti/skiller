import Foundation

/// Creates and inspects the relative symlinks that hold the workspace together.
///
/// Links are always relative so the whole workspace can be moved or synced to another
/// machine without every link breaking.
public enum LinkManager {
    /// How the destination of a link is written.
    ///
    /// Inside the workspace links are always `.relative`, so the whole tree can be moved.
    /// A link from a *project* into the workspace has no such invariant — the two trees move
    /// independently — so `apply` writes those `.absolute`, where a relative path would be
    /// both unreadable and wrong the moment either side moves.
    public enum LinkStyle: Sendable, Hashable {
        case relative
        case absolute
    }

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

    public static func state(of link: URL, expectedTarget: URL, style: LinkStyle = .relative) -> LinkState {
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

        let expected = destinationPath(for: expectedTarget, from: link, style: style)
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

    /// Points `link` at `target`.
    ///
    /// - Parameter replaceExisting: replaces an existing *symlink*. A real file or directory
    ///   is never removed silently — that always throws.
    /// - Parameter style: how the destination is written. See `LinkStyle`.
    public static func createLink(
        at link: URL,
        to target: URL,
        replaceExisting: Bool = false,
        style: LinkStyle = .relative
    ) throws {
        let fileManager = FileManager.default
        let path = filesystemPath(link)

        switch state(of: link, expectedTarget: target, style: style) {
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
        try fileManager.createSymbolicLink(
            atPath: path,
            withDestinationPath: destinationPath(for: target, from: link, style: style)
        )
    }

    /// The literal string stored in the symlink.
    static func destinationPath(for target: URL, from link: URL, style: LinkStyle) -> String {
        switch style {
        case .relative: relativePath(from: link.deletingLastPathComponent(), to: target)
        case .absolute: filesystemPath(target)
        }
    }

    /// The destination of a symlink, resolved against its own directory but *not* followed
    /// any further — a link into `installs/` resolves to the install link itself, not to the
    /// clone behind it.
    ///
    /// `.notDirectory` on purpose: the result is compared against paths built by `Layout`,
    /// and a trailing slash would make two spellings of the same directory unequal.
    public static func resolvedDestination(of link: URL) -> URL? {
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(
            atPath: filesystemPath(link)
        ) else { return nil }
        // `.absoluteURL` before standardizing: a URL built with `relativeTo:` keeps its base,
        // and such a URL never compares equal to the same path spelled absolutely.
        return URL(
            filePath: destination,
            directoryHint: .notDirectory,
            relativeTo: link.deletingLastPathComponent()
        ).absoluteURL.standardizedFileURL
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

    /// Whether two URLs denote the same location, seeing through symlinked directories in the
    /// paths themselves.
    ///
    /// The rest of this type compares paths lexically on purpose, but that is only sound for
    /// two paths built the same way. `FileManager` hands back directory contents with the
    /// symlinks in the *base* path already resolved, so a workspace reached through one — on
    /// macOS `/tmp` and `/var` both are — would otherwise never match the paths `Layout` builds.
    /// Compared as path strings rather than as `URL`s: two URLs for one location differ over
    /// a trailing slash and over whether they carry a base, and neither is worth caring about.
    public static func samePath(_ lhs: URL, _ rhs: URL) -> Bool {
        canonicalPath(lhs) == canonicalPath(rhs)
    }

    static func canonicalPath(_ url: URL) -> String {
        filesystemPath(url.absoluteURL.resolvingSymlinksInPath().standardizedFileURL)
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
