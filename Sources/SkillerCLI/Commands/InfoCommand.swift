import ArgumentParser
import Foundation
import SkillerKit

struct InfoCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "info",
        abstract: "Show what a skill is, installed or not.",
        discussion: """
            Pass an installed name to see its source, commit, groups and contents. Pass a \
            reference like owner/repo/skill-id to look one up before installing — licence and \
            description come from the local registry index, so run `skiller index --refresh` \
            first if you have not.
            """,
        aliases: ["show"]
    )

    @Argument(help: "Installed skill name, or owner/repo/skill-id.")
    var skill: String

    @OptionGroup var workspaceOptions: WorkspaceOptions
    @OptionGroup var output: OutputOptions

    func run() async throws {
        let workspace = try workspaceOptions.resolve()
        let details = try SkillInspector(workspace: workspace).inspect(skill)

        if output.json {
            try printJSON(details)
        } else {
            printReport(details)
        }
    }

    private func printReport(_ details: SkillDetails) {
        let status = details.isInstalled ? "" : "   (not installed)"
        print("\(details.name)\(status)")

        if let description = details.description {
            print("")
            for line in description.wrapped(at: 88) {
                print("  \(line)")
            }
        }

        print("")
        var rows: [(String, String)] = []

        if let locked = details.locked {
            rows.append(("Source", locked.sourceDescription))
            if locked.origin == .git {
                rows.append(("Commit", String(locked.commit.prefix(7)) + (locked.gitRef.map { "  (\($0))" } ?? "")))
            }
            rows.append(("Installed", Self.format(locked.installedAt)))
        } else if let ref = details.candidateRef {
            rows.append(("Source", ref.canonical))
        }

        if let license = details.license {
            let restricted = details.registry?.distribution == "restricted" || license == "NOASSERTION"
            let label = license == "NOASSERTION" ? "unclear — verify upstream" : license
            rows.append(("Licence", restricted ? "⚠ \(label)" : label))
        }
        if let category = details.registry?.category, !category.isEmpty {
            rows.append(("Category", category))
        }
        if let stars = details.registry?.stars, stars > 0 {
            rows.append(("Stars", String(stars)))
        }
        if !details.groups.isEmpty {
            rows.append(("Groups", details.groups.joined(separator: ", ")))
        }
        if let path = details.resolvedPath {
            rows.append(("Content", path))
        }

        let labelWidth = rows.map(\.0.count).max() ?? 0
        for (label, value) in rows {
            print("  \(label.padded(to: labelWidth))  \(value)")
        }

        if !details.contents.isEmpty {
            print("")
            print("  Files")
            let nameWidth = details.contents.map { $0.name.count + ($0.isDirectory ? 1 : 0) }.max() ?? 0
            for entry in details.contents {
                let name = (entry.name + (entry.isDirectory ? "/" : "")).padded(to: nameWidth)
                let detail = entry.isDirectory
                    ? "  \(entry.fileCount) file\(entry.fileCount == 1 ? "" : "s")"
                    : ""
                print("    \(name)\(detail)")
            }
        }

        if !details.isInstalled, let ref = details.candidateRef {
            print("")
            print("  Install with: skiller add \(ref.canonical) --group <group>")
        }
    }

    private func printJSON(_ details: SkillDetails) throws {
        struct Payload: Encodable {
            var name: String
            var installed: Bool
            var description: String?
            var license: String?
            var category: String?
            var stars: Int?
            var source: String?
            var commit: String?
            var gitRef: String?
            var groups: [String]
            var contentPath: String?
            var files: [String]
        }

        let payload = Payload(
            name: details.name,
            installed: details.isInstalled,
            description: details.description,
            license: details.license,
            category: details.registry?.category,
            stars: details.registry?.stars,
            source: details.locked?.sourceDescription ?? details.candidateRef?.canonical,
            commit: details.locked?.commit,
            gitRef: details.locked?.gitRef,
            groups: details.groups,
            contentPath: details.resolvedPath,
            files: details.contents.map { $0.name + ($0.isDirectory ? "/" : "") }
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        print(String(decoding: try encoder.encode(payload), as: UTF8.self))
    }

    private static func format(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}

extension String {
    /// Greedy word wrap. Descriptions in the registry are a single long line.
    func wrapped(at width: Int) -> [String] {
        var lines: [String] = []
        var current = ""
        for word in split(separator: " ") {
            if current.isEmpty {
                current = String(word)
            } else if current.count + 1 + word.count <= width {
                current += " \(word)"
            } else {
                lines.append(current)
                current = String(word)
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }
}
