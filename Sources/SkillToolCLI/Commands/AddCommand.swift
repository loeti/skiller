import ArgumentParser
import Foundation
import SkillToolKit

struct AddCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Clone a skill and expose it under installs/.",
        discussion: """
            The reference can be owner/repo, owner/repo/skill-id, a github.com URL, or the \
            number of a row from the last `skill-tool search`.

            Giving only owner/repo installs every skill in that repository.
            """
    )

    @Argument(help: "Skill reference or search result number.")
    var reference: String

    @Option(name: .long, help: "Install under this name instead of the skill's directory name.")
    var `as`: String?

    @Option(name: .shortAndLong, help: "Also link the skill into this group under skills/.")
    var group: String?

    @Option(name: .long, help: "Branch, tag or commit to check out.")
    var ref: String?

    @Flag(name: .long, help: "Fetch the latest commit even if the repository is already cloned.")
    var update = false

    @OptionGroup var workspaceOptions: WorkspaceOptions

    func run() async throws {
        let workspace = try workspaceOptions.resolve()
        var skillRef = try SkillReferenceResolver.resolve(reference, in: workspace)
        if let ref { skillRef.gitRef = ref }

        var installer = SkillInstaller(workspace: workspace)
        let outcomes = try await installer.install(
            ref: skillRef,
            as: `as`,
            group: group,
            forceUpdate: update
        )

        let layout = installer.workspace.layout
        for outcome in outcomes {
            let commit = String(outcome.commit.prefix(7))
            let state = outcome.wasUpToDate ? "up to date" : "installed"
            print("\(state)  \(outcome.name)  ← \(outcome.ref.canonical) @ \(commit)")
            if let description = outcome.skill.manifest.description {
                print("          \(description.firstLine(maxLength: 100))")
            }
            let installLink = layout.installLink(name: outcome.name)
            let skillDirectory = layout.skillDirectory(
                host: outcome.ref.host,
                owner: outcome.ref.owner,
                repo: outcome.ref.repo,
                skillPath: outcome.skill.relativePath
            )
            print("          installs/\(outcome.name) → \(LinkManager.relativePath(from: layout.installsDirectory, to: skillDirectory))")
            if let group = outcome.group {
                let groupLink = layout.groupLink(group: group, name: outcome.name)
                let target = LinkManager.relativePath(
                    from: groupLink.deletingLastPathComponent(),
                    to: installLink
                )
                print("          skills/\(group)/\(outcome.name) → \(target)")
            }
        }

        if outcomes.count > 1 {
            print("")
            print("\(outcomes.count) skills installed from \(skillRef.repoSlug).")
        }
    }
}

extension String {
    /// First line, truncated — descriptions in the wild run to several paragraphs.
    func firstLine(maxLength: Int) -> String {
        let line = split(separator: "\n", maxSplits: 1).first.map(String.init) ?? self
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count > maxLength else { return trimmed }
        return String(trimmed.prefix(maxLength - 1)) + "…"
    }
}

/// Turns a CLI argument into a `SkillRef`, resolving search-result numbers against the
/// results cached by the last `search`.
enum SkillReferenceResolver {
    static func resolve(_ argument: String, in workspace: Workspace) throws -> SkillRef {
        let trimmed = argument.trimmingCharacters(in: .whitespaces)
        guard let index = Int(trimmed) else {
            return try SkillRef(parsing: trimmed)
        }
        guard index >= 1 else {
            throw CLIError.message("Search result numbers start at 1.")
        }

        let cacheURL = workspace.layout.lastSearchFile
        guard
            let data = try? Data(contentsOf: cacheURL),
            let results = try? JSONDecoder().decode([SkillSearchResult].self, from: data),
            !results.isEmpty
        else {
            throw CLIError.message("No cached search results. Run `skill-tool search <query>` first.")
        }
        guard index <= results.count else {
            throw CLIError.message("The last search returned \(results.count) results; \(index) is out of range.")
        }
        return results[index - 1].ref
    }
}
