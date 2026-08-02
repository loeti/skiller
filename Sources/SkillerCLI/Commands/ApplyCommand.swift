import ArgumentParser
import Foundation
import SkillerKit

struct ApplyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "apply",
        abstract: "Flatten groups into the current project's .claude/skills/.",
        discussion: """
            Every requested group is resolved down to the skills it references, following \
            subgroups as deep as they go. The result is a flat set of links in \
            .claude/skills/ — the intermediate group levels do not appear.

            A skill reachable through more than one group is linked once. Links point at \
            installs/ in the workspace, so `skiller sync --update` reaches applied projects \
            without re-running apply.

            Links are left alone unless they are ours: anything else in .claude/skills/ \
            survives, and --clean only ever removes symlinks, never real directories.
            """
    )

    @Argument(help: "Groups to apply, e.g. ios vpbank.")
    var groups: [String]

    @Flag(name: [.customLong("dry-run"), .customShort("n")], help: "Report what would happen, change nothing.")
    var dryRun = false

    @Flag(name: .shortAndLong, help: "Remove the existing symlinks in .claude/skills/ first.")
    var clean = false

    @Option(
        name: .long,
        help: "Project directory to apply into. Defaults to the current directory."
    )
    var project: String?

    @Flag(name: .long, help: "Leave .gitignore alone.")
    var noGitignore = false

    @OptionGroup var workspaceOptions: WorkspaceOptions

    func run() async throws {
        let workspace = try workspaceOptions.resolve()
        let projectRoot = URL(
            filePath: project ?? FileManager.default.currentDirectoryPath,
            directoryHint: .isDirectory
        ).standardizedFileURL

        guard Workspace.isDirectory(projectRoot) else {
            throw CLIError.message("'\(projectRoot.path(percentEncoded: false))' is not a directory.")
        }
        // Applying a workspace into itself would put links to installs/ under skills/, which
        // is exactly the shape `adopt` and `doctor` treat as a mistake.
        guard projectRoot != workspace.root else {
            throw CLIError.message(
                "The project directory is the workspace itself. Run apply from the project you want the skills in."
            )
        }

        let resolution = try GroupResolver.resolve(groups: groups, in: workspace)
        report(resolution)

        guard !resolution.skills.isEmpty || clean else {
            print("Nothing to apply — \(groups.joined(separator: ", ")) resolves to no skills.")
            return
        }

        let applier = ProjectApplier(projectRoot: projectRoot, workspace: workspace)
        let outcome = try applier.apply(
            resolution.skills,
            clean: clean,
            dryRun: dryRun,
            updateGitignore: !noGitignore
        )
        printOutcome(outcome, applier: applier, resolution: resolution)
    }

    /// Problems found while walking the groups. They never stop the apply — a dangling link in
    /// one corner of a group tree should not withhold the rest of it.
    private func report(_ resolution: GroupResolver.Resolution) {
        for cycle in resolution.cycles {
            print("cycle    \(cycle) — traversal stopped there")
        }
        for path in resolution.deadLinks {
            print("dead     \(path) resolves to nothing")
        }
        for path in resolution.unadopted {
            print("skipped  \(path) is a real directory — run `skiller adopt \(path)`")
        }
        for collision in resolution.collisions {
            print("clash    \(collision)")
        }
        if resolution.hasProblems { print("") }
    }

    private func printOutcome(
        _ outcome: ProjectApplier.Report,
        applier: ProjectApplier,
        resolution: GroupResolver.Resolution
    ) {
        let target = LinkManager.relativePath(from: applier.projectRoot, to: applier.skillsDirectory)
        let sourceGroup = Dictionary(
            resolution.skills.map { ($0.name, $0.sourceGroup) },
            uniquingKeysWith: { first, _ in first }
        )

        for name in outcome.created.sorted() {
            print("link     \(target)/\(name)  ← \(sourceGroup[name] ?? "")")
        }
        for name in outcome.updated.sorted() {
            print("relink   \(target)/\(name)  ← \(sourceGroup[name] ?? "")")
        }
        for name in outcome.removed.sorted() {
            print("remove   \(target)/\(name)")
        }
        for name in outcome.blocked.sorted() {
            print("blocked  \(target)/\(name) is a real file or directory — left untouched")
        }

        print("")
        let verb = dryRun ? "would be applied" : "applied"
        print("\(resolution.skills.count) skill(s) \(verb) to \(target)/ from \(groups.joined(separator: ", ")).")
        if !outcome.unchanged.isEmpty {
            print("\(outcome.unchanged.count) already up to date.")
        }

        if !outcome.stale.isEmpty {
            print(
                "\(outcome.stale.count) link(s) from an earlier apply are not in these groups: "
                    + "\(outcome.stale.sorted().joined(separator: ", ")). Re-run with --clean to drop them."
            )
        }

        switch outcome.gitignore {
        case .created:
            print(dryRun ? "would create .gitignore with '.claude/'" : "created .gitignore with '.claude/'")
        case .appended:
            print(dryRun ? "would add '.claude/' to .gitignore" : "added '.claude/' to .gitignore")
        case .skippedNoRepository:
            print("no .gitignore and no git repository here — left alone")
        case .alreadyCovered, .disabled:
            break
        }

        if dryRun && outcome.madeChanges {
            print("")
            print("Dry run — nothing was written.")
        }
    }
}
