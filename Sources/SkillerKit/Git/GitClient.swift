import Foundation

/// Thin wrapper around the `git` executable.
///
/// Shelling out rather than linking libgit2 keeps the dependency surface at zero and means
/// the user's existing credential helpers, proxies and SSH config all apply unchanged.
public struct GitClient: Sendable {
    public init() {}

    public struct NotInstalled: Error, CustomStringConvertible {
        public var description: String { "`git` was not found on PATH." }
    }

    public func ensureAvailable() async throws {
        guard await ProcessRunner.isAvailable("git") else { throw NotInstalled() }
    }

    // MARK: - Clone

    /// Clones `url` into `directory`, creating parent directories as needed.
    ///
    /// `--branch` handles branches and tags. A raw commit SHA cannot be cloned directly, so a
    /// failed attempt falls back to a full clone followed by a checkout.
    public func clone(
        from url: URL,
        into directory: URL,
        ref: String? = nil,
        depth: Int? = 1,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws {
        try FileManager.default.createDirectory(
            at: directory.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // git suppresses its progress output when stderr is not a terminal, and ours never is —
        // it is captured. `--progress` asks for it anyway, which is the only way a caller can
        // report on a clone that runs for minutes.
        var arguments = ["clone", onProgress == nil ? "--quiet" : "--progress"]
        if let depth { arguments += ["--depth", String(depth)] }
        if let ref { arguments += ["--branch", ref] }
        arguments += [url.absoluteString, directory.path(percentEncoded: false)]

        let result = try await ProcessRunner.run("git", arguments, onProgress: onProgress)
        if result.succeeded { return }

        // Clean up whatever a partial clone left behind before retrying.
        try? FileManager.default.removeItem(at: directory)

        guard let ref else {
            throw ProcessFailure(
                command: "git clone \(url.absoluteString)",
                exitCode: result.exitCode,
                standardError: result.standardError
            )
        }

        // Second attempt: full clone, then check the ref out. Covers commit SHAs and refs
        // that `--branch` cannot resolve.
        try await ProcessRunner.check(
            "git",
            [
                "clone",
                onProgress == nil ? "--quiet" : "--progress",
                url.absoluteString,
                directory.path(percentEncoded: false),
            ],
            onProgress: onProgress
        )
        try await checkout(ref, in: directory)
    }

    /// Checks out an exact commit, fetching it first if the shallow clone does not have it.
    ///
    /// Returns `false` when the commit cannot be obtained — a force-push or a rewritten
    /// history makes a locked commit unreachable, and that should surface as a report line
    /// rather than an aborted sync.
    @discardableResult
    public func ensureCommit(_ commit: String, in directory: URL) async -> Bool {
        let hasCommit = try? await ProcessRunner.check(
            "git",
            ["rev-parse", "--verify", "--quiet", "\(commit)^{commit}"],
            workingDirectory: directory
        )
        if hasCommit != nil {
            return (try? await checkout(commit, in: directory)) != nil
        }

        let fetched = try? await ProcessRunner.check(
            "git",
            ["fetch", "--quiet", "--depth", "1", "origin", commit],
            workingDirectory: directory
        )
        guard fetched != nil else { return false }
        return (try? await checkout(commit, in: directory)) != nil
    }

    public func checkout(_ ref: String, in directory: URL) async throws {
        try await ProcessRunner.check(
            "git",
            ["-c", "advice.detachedHead=false", "checkout", "--quiet", ref],
            workingDirectory: directory
        )
    }

    // MARK: - Update

    /// Fetches and hard-resets the working tree to the tip of `ref` (or the default branch).
    ///
    /// A hard reset is deliberate: `downloads/` is a cache the tool owns, not a place to make
    /// local edits, and merge conflicts there would be a dead end for the user.
    public func update(
        directory: URL,
        ref: String?,
        depth: Int? = 1,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws {
        let target: String
        if let ref {
            target = ref
        } else {
            target = try await defaultBranch(in: directory)
        }

        var fetchArguments = ["fetch", onProgress == nil ? "--quiet" : "--progress"]
        if let depth, await isShallow(directory: directory) {
            fetchArguments += ["--depth", String(depth)]
        }
        fetchArguments += ["origin", target]

        try await ProcessRunner.check(
            "git",
            fetchArguments,
            workingDirectory: directory,
            onProgress: onProgress
        )
        try await ProcessRunner.check(
            "git",
            ["reset", "--hard", "--quiet", "FETCH_HEAD"],
            workingDirectory: directory
        )
    }

    // MARK: - Queries

    public func headCommit(in directory: URL) async throws -> String {
        try await ProcessRunner.check("git", ["rev-parse", "HEAD"], workingDirectory: directory).output
    }

    /// Short SHA for display.
    public func shortCommit(_ commit: String) -> String {
        String(commit.prefix(7))
    }

    public func defaultBranch(in directory: URL) async throws -> String {
        // origin/HEAD is present after a normal clone; fall back to the checked-out branch.
        let symbolic = try? await ProcessRunner.check(
            "git",
            ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"],
            workingDirectory: directory
        ).output
        if let symbolic, let branch = symbolic.split(separator: "/").last {
            return String(branch)
        }
        return try await ProcessRunner.check(
            "git",
            ["rev-parse", "--abbrev-ref", "HEAD"],
            workingDirectory: directory
        ).output
    }

    public func isShallow(directory: URL) async -> Bool {
        let result = try? await ProcessRunner.run(
            "git",
            ["rev-parse", "--is-shallow-repository"],
            workingDirectory: directory
        )
        return result?.output == "true"
    }

    public func isRepository(_ directory: URL) -> Bool {
        Workspace.isDirectory(directory.appending(path: ".git", directoryHint: .isDirectory))
    }

    /// Whether the checkout has uncommitted changes — checked before a destructive update.
    public func hasLocalChanges(in directory: URL) async -> Bool {
        guard let result = try? await ProcessRunner.run(
            "git",
            ["status", "--porcelain"],
            workingDirectory: directory
        ) else { return false }
        return !result.output.isEmpty
    }
}
