import ArgumentParser
import Foundation
import SkillToolKit

struct LinkCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "link",
        abstract: "Link an installed skill into a group under skills/.",
        discussion: "Groups may be nested — `skill-tool link vpbank/bkt <skill>` works."
    )

    @Argument(help: "Group directory under skills/.")
    var group: String

    @Argument(help: "Installed skill names.")
    var names: [String]

    @OptionGroup var workspaceOptions: WorkspaceOptions

    func run() async throws {
        var installer = SkillInstaller(workspace: try workspaceOptions.resolve())
        for name in names {
            try installer.link(name: name, into: group)
            print("linked  skills/\(group)/\(name)")
        }
    }
}

struct UnlinkCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "unlink",
        abstract: "Remove a skill from a group. The install itself stays."
    )

    @Argument(help: "Group directory under skills/.")
    var group: String

    @Argument(help: "Installed skill names.")
    var names: [String]

    @OptionGroup var workspaceOptions: WorkspaceOptions

    func run() async throws {
        var installer = SkillInstaller(workspace: try workspaceOptions.resolve())
        for name in names {
            try installer.unlink(name: name, from: group)
            print("unlinked  skills/\(group)/\(name)")
        }
    }
}

struct RemoveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Remove an install and all of its group links.",
        aliases: ["rm"]
    )

    @Argument(help: "Installed skill names.")
    var names: [String]

    @Flag(name: .long, help: "Also delete the clone once nothing else references it.")
    var prune = false

    @OptionGroup var workspaceOptions: WorkspaceOptions

    func run() async throws {
        var installer = SkillInstaller(workspace: try workspaceOptions.resolve())
        for name in names {
            let outcome = try installer.remove(name: name, prune: prune)
            print("removed  \(outcome.name)")
            for group in outcome.removedGroups {
                print("         skills/\(group)/\(outcome.name)")
            }
            if let pruned = outcome.prunedRepository {
                print("         pruned clone of \(pruned)")
            }
        }
    }
}
