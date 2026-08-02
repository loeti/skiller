import ArgumentParser
import Foundation
import SkillerKit

struct SearchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Search registries for skills."
    )

    enum Source: String, ExpressibleByArgument, CaseIterable {
        case all
        case skillsSh = "skills-sh"
        case github
        case registry

        var origins: [SkillSearchResult.Origin] {
            switch self {
            case .all: SkillSearchResult.Origin.allCases
            case .skillsSh: [.skillsSh]
            case .github: [.gitHub]
            case .registry: [.registry]
            }
        }
    }

    @Argument(help: "What to search for.")
    var query: [String]

    @Option(name: .long, help: "Which registries to query: all, skills-sh, github.")
    var source: Source?

    @Option(name: .shortAndLong, help: "Maximum number of results.")
    var limit: Int = 20

    @OptionGroup var workspaceOptions: WorkspaceOptions
    @OptionGroup var output: OutputOptions

    func run() async throws {
        let searchTerm = query.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !searchTerm.isEmpty else {
            throw CLIError.message("Nothing to search for.")
        }

        // A workspace is optional here — searching before creating one is reasonable.
        var workspace = try? workspaceOptions.resolve()
        let origins = source?.origins ?? workspace?.config.defaultSources ?? SkillSearchResult.Origin.allCases

        let outcome = await MergedRegistry(origins: origins).search(query: searchTerm, limit: limit)

        if workspace != nil {
            try? Self.cacheResults(outcome.results, in: workspace!)
        }
        workspace = nil

        if output.json {
            try printJSON(outcome)
        } else {
            printTable(outcome, searchTerm: searchTerm)
        }
    }

    private func printJSON(_ outcome: RegistrySearchOutcome) throws {
        struct Payload: Encodable {
            var results: [SkillSearchResult]
            var warnings: [String]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(Payload(results: outcome.results, warnings: outcome.warnings))
        print(String(decoding: data, as: UTF8.self))
    }

    private func printTable(_ outcome: RegistrySearchOutcome, searchTerm: String) {
        for warning in outcome.warnings {
            FileHandle.standardError.write(Data("warning: \(warning)\n".utf8))
        }

        guard !outcome.results.isEmpty else {
            print("No skills found for '\(searchTerm)'.")
            return
        }

        let indexWidth = String(outcome.results.count).count
        let nameWidth = outcome.results.map(\.displayName.count).max() ?? 0
        let indent = String(repeating: " ", count: indexWidth + 3)

        for (offset, result) in outcome.results.enumerated() {
            let index = String(offset + 1).padded(to: indexWidth, alignment: .right)
            let name = result.displayName.padded(to: nameWidth)
            let origins = result.origins.map(\.rawValue).sorted().joined(separator: "+")

            var trailing = [popularity(result), licenseMarker(result)].filter { !$0.isEmpty }
            trailing.append("[\(origins)]")
            print("\(index).  \(name)  \(result.ref.canonical)  \(trailing.joined(separator: "  "))")

            if let description = result.description, !description.isEmpty {
                print("\(indent)\(description.firstLine(maxLength: 110))")
            }
        }

        print("")
        print("Install with: skiller add <number|owner/repo/skill-id> --group <group>")
        if !outcome.results.contains(where: { $0.origins.contains(.registry) }),
           !RegistryIndexCache().exists {
            print("Descriptions and licences come from the community registry: skiller index --refresh")
        }
    }

    private func popularity(_ result: SkillSearchResult) -> String {
        var parts: [String] = []
        if let installs = result.installs { parts.append("\(installs.abbreviated) installs") }
        if let stars = result.stars { parts.append("★\(stars.abbreviated)") }
        return parts.joined(separator: " ")
    }

    /// Licence is the one field worth surfacing before install rather than after — an
    /// unclear licence is a reason not to install at all in some settings.
    private func licenseMarker(_ result: SkillSearchResult) -> String {
        guard let label = result.licenseLabel else { return "" }
        return result.isLicenseRestricted ? "⚠ \(label)" : label
    }

    private static func cacheResults(_ results: [SkillSearchResult], in workspace: Workspace) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(results)
        try FileManager.default.createDirectory(
            at: workspace.layout.stateDirectory,
            withIntermediateDirectories: true
        )
        try data.write(to: workspace.layout.lastSearchFile, options: .atomic)
    }
}

extension String {
    enum Alignment { case left, right }

    func padded(to width: Int, alignment: Alignment = .left) -> String {
        guard count < width else { return self }
        let padding = String(repeating: " ", count: width - count)
        return alignment == .left ? self + padding : padding + self
    }
}

extension Int {
    /// 27980 → "28.0k". Keeps the search table narrow.
    var abbreviated: String {
        switch self {
        case ..<1_000: String(self)
        case ..<1_000_000: String(format: "%.1fk", Double(self) / 1_000)
        default: String(format: "%.1fM", Double(self) / 1_000_000)
        }
    }
}
