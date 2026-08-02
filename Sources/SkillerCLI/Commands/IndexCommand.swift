import ArgumentParser
import Foundation
import SkillerKit

struct IndexCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "index",
        abstract: "Manage the local copy of the community skill registry.",
        discussion: """
            The registry is a static, keyless artifact of ~160k skills. It is the only source \
            that carries a description and a licence per skill, and once downloaded, searching \
            it costs nothing and works offline.

            The download is roughly 18 MB across 256 shards. Run `index --refresh` once, then \
            again whenever you want fresher data — upstream regenerates about daily.
            """
    )

    @Flag(name: .long, help: "Download the registry and rebuild the local index.")
    var refresh = false

    @Flag(name: .long, help: "Delete the local index.")
    var clear = false

    func run() async throws {
        let cache = RegistryIndexCache()

        if clear {
            try cache.clear()
            print("Local registry index removed.")
            return
        }

        guard refresh else {
            printStatus(cache)
            return
        }

        print("Downloading registry from \(cache.baseURL.absoluteString)")
        let metadata = try await cache.refresh { progress in
            // Carriage return keeps this to a single line in a terminal.
            let percent = progress.totalShards == 0
                ? 0
                : progress.completedShards * 100 / progress.totalShards
            FileHandle.standardError.write(
                Data("\r  \(percent)%  \(progress.completedShards)/\(progress.totalShards) shards  \(progress.records) skills".utf8)
            )
        }
        FileHandle.standardError.write(Data("\r\u{1B}[K".utf8))

        print("Indexed \(metadata.recordCount) skills.")
        print("Registry generated \(metadata.registryGeneratedAt).")
    }

    private func printStatus(_ cache: RegistryIndexCache) {
        guard let metadata = cache.metadata() else {
            print("No local registry index.")
            print("Build it with: skiller index --refresh")
            return
        }

        print("Skills:    \(metadata.recordCount)")
        print("Source:    \(metadata.source)")
        print("Generated: \(metadata.registryGeneratedAt)")
        print("Fetched:   \(Self.describe(age: metadata.age)) ago\(metadata.isStale ? "  (stale — consider --refresh)" : "")")
        print("Location:  \(cache.directory.path(percentEncoded: false))")
    }

    private static func describe(age: TimeInterval) -> String {
        let hours = Int(age / 3600)
        if hours < 1 { return "\(max(Int(age / 60), 1)) minutes" }
        if hours < 48 { return "\(hours) hours" }
        return "\(hours / 24) days"
    }
}
