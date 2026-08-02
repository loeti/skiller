import ArgumentParser
import Foundation
import SkillerKit

struct InitCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Create the workspace directory skeleton."
    )

    @Argument(help: "Workspace root. Defaults to the current directory.")
    var path: String?

    func run() async throws {
        let root = URL(
            filePath: path ?? FileManager.default.currentDirectoryPath,
            directoryHint: .isDirectory
        ).standardizedFileURL

        let workspace = try Workspace.create(at: root)
        let layout = workspace.layout

        print("Workspace ready at \(layout.root.path(percentEncoded: false))")
        for directory in [layout.stateDirectory, layout.downloadsDirectory, layout.installsDirectory, layout.skillsDirectory] {
            print("  \(LinkManager.relativePath(from: layout.root, to: directory))/")
        }
    }
}
