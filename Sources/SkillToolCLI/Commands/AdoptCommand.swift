import ArgumentParser
import Foundation
import SkillToolKit

struct AdoptCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "adopt",
        abstract: "Turn skill directories you already have into managed installs.",
        discussion: """
            Each directory is moved to installs/<name> and its old location becomes a symlink, \
            so existing grouping keeps working. Content is never rewritten.

            With no arguments every real skill directory under skills/ is adopted. Run with \
            --dry-run first to see what would move.
            """
    )

    @Argument(help: "Directories to adopt. Defaults to every candidate under skills/.")
    var paths: [String] = []

    @Option(name: .long, help: "Install under this name. Only valid with a single directory.")
    var `as`: String?

    @Flag(name: .long, help: "Show what would happen without moving anything.")
    var dryRun = false

    @Flag(name: .long, help: "Look each adopted skill up in the registries and report possible sources.")
    var suggest = false

    @OptionGroup var workspaceOptions: WorkspaceOptions

    func run() async throws {
        let workspace = try workspaceOptions.resolve()
        var installer = SkillInstaller(workspace: workspace)

        let candidates: [URL]
        if paths.isEmpty {
            candidates = installer.adoptionCandidates()
        } else {
            candidates = paths.map { URL(filePath: $0, directoryHint: .isDirectory).standardizedFileURL }
        }

        guard !candidates.isEmpty else {
            print("No real skill directories found under skills/.")
            return
        }
        if `as` != nil, candidates.count > 1 {
            throw CLIError.message("--as only works with a single directory; \(candidates.count) matched.")
        }

        if dryRun {
            print("Would adopt \(candidates.count) director\(candidates.count == 1 ? "y" : "ies"):")
            for candidate in candidates {
                let name = `as` ?? candidate.lastPathComponent
                let from = LinkManager.relativePath(from: workspace.root, to: candidate)
                print("  \(from)  →  installs/\(name)  (link left behind at \(from))")
            }
            return
        }

        var adopted: [SkillInstaller.AdoptionOutcome] = []
        for candidate in candidates {
            do {
                let outcome = try installer.adopt(directory: candidate, as: `as`)
                adopted.append(outcome)
                print("adopted  \(outcome.name)")
                print("         moved   \(outcome.previousPath) → installs/\(outcome.name)")
                for group in outcome.groups {
                    let link = installer.workspace.layout.groupLink(group: group, name: outcome.name)
                    let target = LinkManager.relativePath(
                        from: link.deletingLastPathComponent(),
                        to: installer.workspace.layout.installLink(name: outcome.name)
                    )
                    print("         linked  skills/\(group)/\(outcome.name) → \(target)")
                }
            } catch {
                print("skipped  \(LinkManager.relativePath(from: workspace.root, to: candidate)): \(error)")
            }
        }

        guard suggest, !adopted.isEmpty else { return }
        print("")
        print("Looking for upstream sources…")
        let registry = MergedRegistry(origins: installer.workspace.config.defaultSources)
        for outcome in adopted {
            let results = await registry.search(query: outcome.name, limit: 3).results
            // Only a directory-name match is worth showing; anything looser is noise.
            let matches = results.filter {
                $0.ref.defaultInstallName.caseInsensitiveCompare(outcome.name) == .orderedSame
            }
            guard !matches.isEmpty else { continue }
            print("  \(outcome.name):")
            for match in matches {
                print("    \(match.ref.canonical)")
            }
            print("    replace with a tracked copy: skill-tool remove \(outcome.name) --prune && skill-tool add \(matches[0].ref.canonical)")
        }
    }
}
