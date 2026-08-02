import ArgumentParser
import Foundation
import SkillerKit

struct SyncCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sync",
        abstract: "Rebuild clones and links from the lock file.",
        discussion: """
            Without --update this reproduces the locked state: missing clones are fetched and \
            checked out at their recorded commit, and broken links are repaired.

            With --update every skill moves to the tip of its ref and the lock file is rewritten.
            """
    )

    @Flag(name: .long, help: "Fetch new commits instead of restoring the locked ones.")
    var update = false

    @OptionGroup var workspaceOptions: WorkspaceOptions

    func run() async throws {
        var installer = SkillInstaller(workspace: try workspaceOptions.resolve())
        let report = try await installer.sync(update: update)

        for line in report.cloned { print("cloned    \(line)") }
        for line in report.updated { print("updated   \(line)") }
        for line in report.relinked { print("relinked  \(line)") }
        for line in report.relicensed { print("licence   \(line)") }
        for line in report.failures { print("failed    \(line)") }

        if !report.madeChanges && report.failures.isEmpty {
            print(update ? "Everything already at the latest commit." : "Workspace already matches the lock file.")
        }
        if !report.failures.isEmpty {
            throw ExitCode.failure
        }
    }
}

struct DoctorCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Report inconsistencies. Never changes anything."
    )

    @OptionGroup var workspaceOptions: WorkspaceOptions
    @OptionGroup var output: OutputOptions

    func run() async throws {
        let workspace = try workspaceOptions.resolve()
        let issues = WorkspaceDoctor.diagnose(workspace)

        if output.json {
            struct Row: Encodable {
                var kind: String
                var path: String
                var detail: String
                var fix: String
                var repairableBySync: Bool
            }
            let rows = issues.map {
                Row(kind: $0.kind.rawValue, path: $0.path, detail: $0.detail, fix: $0.fix, repairableBySync: $0.isRepairableBySync)
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            print(String(decoding: try encoder.encode(rows), as: UTF8.self))
            if !issues.isEmpty { throw ExitCode.failure }
            return
        }

        guard !issues.isEmpty else {
            print("No problems found in \(workspace.root.path(percentEncoded: false)).")
            return
        }

        let repairable = issues.filter(\.isRepairableBySync)
        for issue in issues {
            print("\(issue.kind.rawValue)")
            print("  \(issue.path)")
            print("  \(issue.detail)")
            print("  fix: \(issue.fix)")
        }

        print("")
        print("\(issues.count) issue(s).", terminator: "")
        if repairable.isEmpty {
            print("")
        } else {
            print(" \(repairable.count) can be repaired with `skiller sync`.")
        }
        throw ExitCode.failure
    }
}
