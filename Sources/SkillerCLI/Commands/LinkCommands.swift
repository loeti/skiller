import ArgumentParser
import Foundation
import SkillerKit

struct LinkCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "link",
        abstract: "Link an installed skill — or another group — into a group under skills/.",
        discussion: """
            Groups may be nested — `skiller link vpbank/bkt <skill>` works.

            A name that is not an installed skill but is a group is linked as a subgroup, so \
            `skiller link ios swift swiftui` collects both groups under 'ios'. `skiller apply` \
            flattens that nesting again.
            """
    )

    @Argument(help: "Group directory under skills/.")
    var group: String

    @Argument(help: "Installed skill names, or group names.")
    var names: [String]

    @Flag(name: .long, help: "Treat every name as a group, even if a skill goes by it too.")
    var asGroup = false

    @OptionGroup var workspaceOptions: WorkspaceOptions

    func run() async throws {
        var installer = SkillInstaller(workspace: try workspaceOptions.resolve())
        for name in names {
            // A name that is both would otherwise be decided by a coin flip; say so instead.
            // Everything unrecognised goes down the skill path, whose error already explains
            // that nothing is installed under that name.
            switch (asGroup, installer.isInstalled(name), installer.isGroup(name)) {
            case (true, _, _), (false, false, true):
                let linked = try installer.linkGroup(name, into: group)
                print("linked  skills/\(group)/\(linked)  (group)")
            case (false, true, true):
                throw SkillInstaller.InstallError.ambiguousLinkTarget(name)
            case (false, _, false):
                try installer.link(name: name, into: group)
                print("linked  skills/\(group)/\(name)")
            }
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
