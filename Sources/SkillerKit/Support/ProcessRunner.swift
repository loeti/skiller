import Foundation

public struct ProcessResult: Sendable {
    public var exitCode: Int32
    public var standardOutput: String
    public var standardError: String

    public var succeeded: Bool { exitCode == 0 }

    /// Trimmed stdout — what you almost always want from a git query.
    public var output: String {
        standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct ProcessFailure: Error, CustomStringConvertible {
    public var command: String
    public var exitCode: Int32
    public var standardError: String

    public var description: String {
        let detail = standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.isEmpty
            ? "`\(command)` failed with exit code \(exitCode)."
            : "`\(command)` failed with exit code \(exitCode):\n\(detail)"
    }
}

/// Minimal async wrapper around `Process`.
///
/// Output is captured through temporary files rather than pipes: a pipe whose buffer fills
/// before it is drained deadlocks the child process, and `git clone` on a large repository
/// produces more than enough progress output to hit that.
public enum ProcessRunner {
    /// - Parameter onProgress: called with each line the command writes to standard error
    ///   *while it runs*. Standard error is still captured in full for the result.
    public static func run(
        _ executable: String,
        _ arguments: [String],
        workingDirectory: URL? = nil,
        environment: [String: String]? = nil,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> ProcessResult {
        let commandDescription = ([executable] + arguments).joined(separator: " ")
        return try await Task.detached(priority: .userInitiated) {
            try runSynchronously(
                executable: executable,
                arguments: arguments,
                workingDirectory: workingDirectory,
                environment: environment,
                commandDescription: commandDescription,
                onProgress: onProgress
            )
        }.value
    }

    /// Runs a command and throws `ProcessFailure` unless it exits with 0.
    @discardableResult
    public static func check(
        _ executable: String,
        _ arguments: [String],
        workingDirectory: URL? = nil,
        environment: [String: String]? = nil,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> ProcessResult {
        let result = try await run(
            executable,
            arguments,
            workingDirectory: workingDirectory,
            environment: environment,
            onProgress: onProgress
        )
        guard result.succeeded else {
            throw ProcessFailure(
                command: ([executable] + arguments).joined(separator: " "),
                exitCode: result.exitCode,
                standardError: result.standardError.isEmpty ? result.standardOutput : result.standardError
            )
        }
        return result
    }

    /// Whether an executable can be found on `PATH`.
    public static func isAvailable(_ executable: String) async -> Bool {
        let result = try? await run("/usr/bin/which", [executable])
        return result?.succeeded ?? false
    }

    private static func runSynchronously(
        executable: String,
        arguments: [String],
        workingDirectory: URL?,
        environment: [String: String]?,
        commandDescription: String,
        onProgress: (@Sendable (String) -> Void)?
    ) throws -> ProcessResult {
        let fileManager = FileManager.default
        let scratch = fileManager.temporaryDirectory
            .appending(path: "skiller-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: scratch) }

        let outURL = scratch.appending(path: "stdout", directoryHint: .notDirectory)
        let errURL = scratch.appending(path: "stderr", directoryHint: .notDirectory)
        fileManager.createFile(atPath: outURL.path(percentEncoded: false), contents: nil)
        fileManager.createFile(atPath: errURL.path(percentEncoded: false), contents: nil)

        let outHandle = try FileHandle(forWritingTo: outURL)
        let errHandle = try FileHandle(forWritingTo: errURL)
        defer {
            try? outHandle.close()
            try? errHandle.close()
        }

        let process = Process()
        // Going through `env` means callers can pass a bare tool name and get PATH lookup.
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = [executable] + arguments
        process.standardOutput = outHandle
        process.standardError = errHandle
        process.standardInput = FileHandle.nullDevice
        if let workingDirectory { process.currentDirectoryURL = workingDirectory }
        if let environment {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }

        do {
            try process.run()
        } catch {
            throw ProcessFailure(
                command: commandDescription,
                exitCode: -1,
                standardError: "Could not launch: \(error.localizedDescription)"
            )
        }
        if let onProgress {
            // Tailing the capture file rather than reading a pipe: the file-based design exists
            // to avoid the deadlock a full pipe buffer causes, and progress must not bring it back.
            let reader = try? FileHandle(forReadingFrom: errURL)
            var pending = ""
            while process.isRunning {
                Thread.sleep(forTimeInterval: 0.1)
                emitProgress(from: reader, pending: &pending, onProgress)
            }
            emitProgress(from: reader, pending: &pending, onProgress)
            if !pending.isEmpty { onProgress(pending) }
            try? reader?.close()
        }
        process.waitUntilExit()

        let stdout = (try? String(contentsOf: outURL, encoding: .utf8)) ?? ""
        let stderr = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
        return ProcessResult(
            exitCode: process.terminationStatus,
            standardOutput: stdout,
            standardError: stderr
        )
    }

    /// Hands whatever has been written since the last call to `onProgress`, line by line.
    ///
    /// A carriage return counts as a line break: git overwrites its progress line with `\r`
    /// rather than starting a new one, so splitting on newlines alone would deliver one giant
    /// line at the very end — exactly the silence this is meant to fix.
    private static func emitProgress(
        from handle: FileHandle?,
        pending: inout String,
        _ onProgress: (String) -> Void
    ) {
        guard let handle, let data = try? handle.readToEnd(), !data.isEmpty else { return }
        splitProgress(String(decoding: data, as: UTF8.self), pending: &pending, onProgress)
    }

    /// The line splitting on its own, so it can be tested without a live child process.
    static func splitProgress(
        _ chunk: String,
        pending: inout String,
        _ onProgress: (String) -> Void
    ) {
        pending += chunk

        var segments = pending.split(
            omittingEmptySubsequences: false,
            whereSeparator: { $0 == "\r" || $0 == "\n" }
        )
        // The last segment may be half-written; keep it until its terminator arrives.
        pending = segments.popLast().map(String.init) ?? ""
        for segment in segments {
            let line = segment.trimmingCharacters(in: .whitespaces)
            if !line.isEmpty { onProgress(line) }
        }
    }
}
