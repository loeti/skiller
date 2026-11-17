import ArgumentParser
import Foundation
import SkillerKit

struct RollbackCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rollback",
        abstract: "Return a skill to the commit it had before its last update.",
        discussion: """
            `sync --update` and `add --update` record the commit they move away from. Rollback \
            checks that commit out again; running it twice undoes the rollback.

            Skills from the same repository share one clone and move together. Nothing is \
            pinned: the next `sync --update` brings the skill forward again.
            """
    )

    @Argument(help: "Installed skill name.")
    var name: String

    @OptionGroup var workspaceOptions: WorkspaceOptions

    func run() async throws {
        var installer = SkillInstaller(workspace: try workspaceOptions.resolve())
        let outcome = try await installer.rollback(name: name)

        print("rolled back  \(outcome.name): \(outcome.from.prefix(7)) → \(outcome.to.prefix(7))")
        for sibling in outcome.alsoMoved {
            print("also moved   \(sibling) (same repository)")
        }
        print("The next `skiller sync --update` moves it forward again.")
    }
}
