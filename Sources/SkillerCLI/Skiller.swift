import ArgumentParser
import Foundation
import SkillerKit

@main
struct Skiller: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "skiller",
        abstract: "Find agent skills, check them out locally, and group them with symlinks.",
        version: "0.2.1",
        subcommands: [
            InitCommand.self,
            SearchCommand.self,
            IndexCommand.self,
            AddCommand.self,
            LinkCommand.self,
            UnlinkCommand.self,
            ApplyCommand.self,
            ListCommand.self,
            InfoCommand.self,
            RemoveCommand.self,
            SyncCommand.self,
            DoctorCommand.self,
            AdoptCommand.self,
        ]
    )
}

/// Options every workspace-bound subcommand shares.
struct WorkspaceOptions: ParsableArguments {
    @Option(
        name: [.customLong("workspace"), .customShort("w")],
        help: "Workspace root. Defaults to $\(Workspace.environmentVariable), then the nearest parent containing \(Layout.stateDirectoryName)/."
    )
    var workspace: String?

    func resolve() throws -> Workspace {
        try Workspace.resolve(explicit: workspace)
    }
}

/// Output formatting shared by read-only commands.
struct OutputOptions: ParsableArguments {
    @Flag(name: .long, help: "Emit JSON instead of a table.")
    var json = false
}

enum CLIError: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case .message(let text): text
        }
    }
}
