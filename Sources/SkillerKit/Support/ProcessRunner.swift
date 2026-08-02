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
    public static func run(
        _ executable: String,
        _ arguments: [String],
        workingDirectory: URL? = nil,
        environment: [String: String]? = nil
    ) async throws -> ProcessResult {
        let commandDescription = ([executable] + arguments).joined(separator: " ")
        return try await Task.detached(priority: .userInitiated) {
            try runSynchronously(
                executable: executable,
                arguments: arguments,
                workingDirectory: workingDirectory,
                environment: environment,
                commandDescription: commandDescription
            )
        }.value
    }

    /// Runs a command and throws `ProcessFailure` unless it exits with 0.
    @discardableResult
    public static func check(
        _ executable: String,
        _ arguments: [String],
        workingDirectory: URL? = nil,
        environment: [String: String]? = nil
    ) async throws -> ProcessResult {
        let result = try await run(
            executable,
            arguments,
            workingDirectory: workingDirectory,
            environment: environment
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
        commandDescription: String
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
        process.waitUntilExit()

        let stdout = (try? String(contentsOf: outURL, encoding: .utf8)) ?? ""
        let stderr = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
        return ProcessResult(
            exitCode: process.terminationStatus,
            standardOutput: stdout,
            standardError: stderr
        )
    }
}
