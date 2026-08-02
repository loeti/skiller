import ArgumentParser
import Foundation
import SkillToolKit

struct ListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "Show installed skills, or the group tree.",
        aliases: ["ls"]
    )

    @Flag(name: .long, help: "Show groups and their members instead of the install table.")
    var groups = false

    @Flag(name: .long, help: "Show the licence of every installed skill.")
    var licenses = false

    @OptionGroup var workspaceOptions: WorkspaceOptions
    @OptionGroup var output: OutputOptions

    func run() async throws {
        let workspace = try workspaceOptions.resolve()

        if output.json {
            try printJSON(workspace)
        } else if groups {
            printGroups(workspace)
        } else if licenses {
            printLicenses(workspace)
        } else {
            printInstalls(workspace)
        }
    }

    /// Audit view: one row per skill, flagging anything whose licence is unclear.
    private func printLicenses(_ workspace: Workspace) {
        let entries = workspace.lock.skills
        guard !entries.isEmpty else {
            print("Nothing installed.")
            return
        }

        let nameWidth = entries.map(\.name.count).max() ?? 0
        let licenseWidth = entries.map { ($0.license ?? "unknown").count }.max() ?? 0

        for entry in entries {
            let flag = entry.needsLicenseReview ? "⚠" : " "
            let license = (entry.license ?? "unknown").padded(to: licenseWidth)
            var notes: [String] = []
            if let source = entry.licenseSource { notes.append("via \(source.rawValue)") }
            if let distribution = entry.distribution { notes.append(distribution) }
            if let file = entry.licenseFile { notes.append(file) }
            print("\(flag) \(entry.name.padded(to: nameWidth))  \(license)  \(notes.joined(separator: "  "))")
        }

        let review = entries.filter(\.needsLicenseReview)
        print("")
        if review.isEmpty {
            print("All \(entries.count) skills carry an identified licence.")
        } else {
            print("\(review.count) of \(entries.count) need a look before anything ships: \(review.map(\.name).joined(separator: ", "))")
        }
        print("Run `skill-tool sync` to refresh licence data for older entries.")
    }

    private func printInstalls(_ workspace: Workspace) {
        let entries = workspace.lock.skills
        let untracked = workspace.installedNames().filter { name in
            !entries.contains { $0.name == name }
        }

        guard !entries.isEmpty || !untracked.isEmpty else {
            print("Nothing installed. Try `skill-tool search <query>`.")
            return
        }

        let nameWidth = max(
            entries.map(\.name.count).max() ?? 0,
            untracked.map(\.count).max() ?? 0
        )
        let sourceWidth = entries.map(\.sourceDescription.count).max() ?? 0

        for entry in entries {
            let name = entry.name.padded(to: nameWidth)
            let source = entry.sourceDescription.padded(to: sourceWidth)
            let commit = entry.commit.isEmpty ? "       " : String(entry.commit.prefix(7))
            let groups = entry.groups.isEmpty ? "—" : entry.groups.joined(separator: ", ")
            print("\(name)  \(source)  \(commit)  \(groups)")
        }

        for name in untracked {
            print("\(name.padded(to: nameWidth))  \("(untracked)".padded(to: sourceWidth))")
        }

        if !untracked.isEmpty {
            print("")
            print("\(untracked.count) install(s) not in the lock file — run `skill-tool doctor`.")
        }
    }

    private func printGroups(_ workspace: Workspace) {
        let groups = workspace.groups()
        guard !groups.isEmpty else {
            print("No groups yet. Create one with `skill-tool link <group> <skill>`.")
            return
        }

        for group in groups {
            let links = LinkManager.symlinks(in: workspace.layout.groupDirectory(group))
            // A parent that only holds subgroups has no links of its own; still worth showing.
            print("\(group)/")
            for link in links {
                let name = link.lastPathComponent
                let state = LinkManager.state(
                    of: link,
                    expectedTarget: workspace.layout.installLink(name: name)
                )
                let marker = state == .correct ? " " : "!"
                print("  \(marker) \(name)")
            }
        }
    }

    private func printJSON(_ workspace: Workspace) throws {
        struct Payload: Encodable {
            var root: String
            var skills: [LockedSkill]
            var groups: [String]
            var untracked: [String]
        }
        let tracked = Set(workspace.lock.skills.map(\.name))
        let payload = Payload(
            root: workspace.root.path(percentEncoded: false),
            skills: workspace.lock.skills,
            groups: workspace.groups(),
            untracked: workspace.installedNames().filter { !tracked.contains($0) }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        print(String(decoding: try encoder.encode(payload), as: UTF8.self))
    }
}
