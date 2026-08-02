import Foundation

/// One row of the locally cached registry index.
public struct RegistryRecord: Sendable, Hashable {
    public var name: String
    public var repo: String
    public var path: String
    public var branch: String
    public var stars: Int
    public var license: String
    public var distribution: String
    public var category: String
    public var description: String

    public var ref: SkillRef? {
        let parts = repo.split(separator: "/").map(String.init)
        guard parts.count == 2 else { return nil }
        return SkillRef(
            owner: parts[0],
            repo: parts[1],
            skillID: path.isEmpty ? nil : path
        )
    }
}

/// Downloads and stores the sharded community registry so searching is local and unmetered.
///
/// The registry (`majiayu000/claude-skill-registry`) is a static artifact on
/// raw.githubusercontent.com: a manifest plus 256 shards. It carries what the live APIs do not —
/// a description *and* license/distribution per skill — and needs no credentials.
///
/// Shards are keyed by `sha256(install|branch)`, so there is no way to look one skill up by
/// name: it is all 256 or nothing. At ~72 KB gzip each that is ~18 MB once, which is why this
/// is an explicit `skill-tool index --refresh` rather than something a search triggers.
public struct RegistryIndexCache: Sendable {
    public static let defaultBaseURL = URL(
        string: "https://raw.githubusercontent.com/majiayu000/claude-skill-registry/main"
    )!

    /// Rebuild prompt threshold. The upstream regenerates roughly daily.
    public static let staleAfter: TimeInterval = 24 * 60 * 60

    public let baseURL: URL
    public let directory: URL

    public init(baseURL: URL = RegistryIndexCache.defaultBaseURL, directory: URL? = nil) {
        self.baseURL = baseURL
        self.directory = directory ?? Self.defaultDirectory()
    }

    /// `$XDG_CACHE_HOME/skill-tool` or `~/.cache/skill-tool` — shared across workspaces, since
    /// the registry has nothing to do with any one of them.
    public static func defaultDirectory() -> URL {
        let environment = ProcessInfo.processInfo.environment
        if let xdg = environment["XDG_CACHE_HOME"], !xdg.isEmpty {
            return URL(filePath: xdg, directoryHint: .isDirectory)
                .appending(path: "skill-tool", directoryHint: .isDirectory)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".cache/skill-tool", directoryHint: .isDirectory)
    }

    var indexFile: URL { directory.appending(path: "registry-index.tsv", directoryHint: .notDirectory) }
    var metadataFile: URL { directory.appending(path: "registry-meta.json", directoryHint: .notDirectory) }

    // MARK: - Metadata

    public struct Metadata: Codable, Sendable {
        public var recordCount: Int
        /// When the upstream generated the shards.
        public var registryGeneratedAt: String
        /// When we last downloaded them.
        public var fetchedAt: Date
        public var source: String

        public var age: TimeInterval { Date().timeIntervalSince(fetchedAt) }
        public var isStale: Bool { age > RegistryIndexCache.staleAfter }
    }

    public func metadata() -> Metadata? {
        guard
            let data = try? Data(contentsOf: metadataFile),
            let metadata = try? LockFile.decoder.decode(Metadata.self, from: data)
        else { return nil }
        return metadata
    }

    public var exists: Bool {
        FileManager.default.fileExists(atPath: indexFile.path(percentEncoded: false))
    }

    // MARK: - Refresh

    public struct RefreshProgress: Sendable {
        public var completedShards: Int
        public var totalShards: Int
        public var records: Int
    }

    /// Downloads every shard and writes a flat index.
    ///
    /// - Parameter onProgress: called as shards land, for a progress line on the CLI.
    @discardableResult
    public func refresh(
        onProgress: (@Sendable (RefreshProgress) -> Void)? = nil
    ) async throws -> Metadata {
        let manifest = try await HTTPClient.getJSON(
            Manifest.self,
            url: baseURL.appending(path: "registry-manifest.json"),
            registryName: SkillSearchResult.Origin.registry.rawValue
        )

        let total = manifest.shards.count
        var records: [RegistryRecord] = []
        records.reserveCapacity(manifest.totalCount)
        var completed = 0

        // raw.githubusercontent is fine with a dozen parallel requests; more just invites
        // throttling for no wall-clock gain.
        let batchSize = 12
        for batch in manifest.shards.chunked(into: batchSize) {
            let fetched = try await withThrowingTaskGroup(of: [RegistryRecord].self) { group in
                for shard in batch {
                    group.addTask {
                        // `.json` (not `.json.gz`) — GitHub serves it Content-Encoding: gzip,
                        // which URLSession unwraps for us. Same bytes on the wire, no gzip code.
                        let shardResponse = try await HTTPClient.getJSON(
                            Shard.self,
                            url: baseURL.appending(path: shard.path),
                            registryName: SkillSearchResult.Origin.registry.rawValue
                        )
                        return shardResponse.skills.map(\.record)
                    }
                }
                var collected: [RegistryRecord] = []
                for try await shardRecords in group {
                    collected.append(contentsOf: shardRecords)
                }
                return collected
            }
            records.append(contentsOf: fetched)
            completed += batch.count
            onProgress?(RefreshProgress(completedShards: completed, totalShards: total, records: records.count))
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try write(records)

        let metadata = Metadata(
            recordCount: records.count,
            registryGeneratedAt: manifest.generatedAt,
            fetchedAt: Date(),
            source: baseURL.absoluteString
        )
        try LockFile.encoder.encode(metadata).write(to: metadataFile, options: .atomic)
        return metadata
    }

    // MARK: - Storage
    //
    // Tab-separated rather than JSON: 160k records decode through JSONDecoder in seconds,
    // which is far too slow for something that runs on every search. Splitting lines is
    // roughly an order of magnitude faster and the schema here is flat anyway.

    static let separator: Character = "\t"

    func write(_ records: [RegistryRecord]) throws {
        var output = ""
        output.reserveCapacity(records.count * 320)
        for record in records {
            output += [
                Self.sanitize(record.name),
                Self.sanitize(record.repo),
                Self.sanitize(record.path),
                Self.sanitize(record.branch),
                String(record.stars),
                Self.sanitize(record.license),
                Self.sanitize(record.distribution),
                Self.sanitize(record.category),
                // Headroom rather than a real limit: the shards already cap descriptions at
                // 200 characters upstream. Not clipping further means a future registry that
                // stores the full text works without a code change.
                Self.sanitize(record.description, maxLength: 600),
            ].joined(separator: String(Self.separator))
            output += "\n"
        }
        try output.write(to: indexFile, atomically: true, encoding: .utf8)
    }

    public func load() throws -> [RegistryRecord] {
        guard exists else { return [] }
        let text = try String(contentsOf: indexFile, encoding: .utf8)
        var records: [RegistryRecord] = []
        records.reserveCapacity(200_000)

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(separator: Self.separator, omittingEmptySubsequences: false)
            guard fields.count >= 9 else { continue }
            records.append(
                RegistryRecord(
                    name: String(fields[0]),
                    repo: String(fields[1]),
                    path: String(fields[2]),
                    branch: String(fields[3]),
                    stars: Int(fields[4]) ?? 0,
                    license: String(fields[5]),
                    distribution: String(fields[6]),
                    category: String(fields[7]),
                    description: String(fields[8])
                )
            )
        }
        return records
    }

    public func clear() throws {
        for url in [indexFile, metadataFile] where FileManager.default.fileExists(
            atPath: url.path(percentEncoded: false)
        ) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Tabs and newlines would break the row format; descriptions in the registry contain both.
    static func sanitize(_ value: String, maxLength: Int = 200) -> String {
        var cleaned = value
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespaces)
        if cleaned.count > maxLength {
            cleaned = String(cleaned.prefix(maxLength - 1)) + "…"
        }
        return cleaned
    }

    // MARK: - Upstream shapes

    struct Manifest: Decodable {
        struct Shard: Decodable, Sendable {
            var id: String
            var path: String
            var count: Int
        }

        var generatedAt: String
        var totalCount: Int
        var shards: [Shard]

        enum CodingKeys: String, CodingKey {
            case generatedAt = "generated_at"
            case totalCount = "total_count"
            case shards
        }
    }

    struct Shard: Decodable {
        struct Entry: Decodable {
            var name: LooseString?
            var description: LooseString?
            var repo: LooseString?
            var path: LooseString?
            var branch: LooseString?
            var category: LooseString?
            var stars: LooseInt?
            var license: LooseString?
            var distribution: LooseString?

            var record: RegistryRecord {
                RegistryRecord(
                    name: name?.value ?? "",
                    repo: repo?.value ?? "",
                    path: Self.skillDirectory(from: path?.value ?? ""),
                    branch: branch?.value.isEmpty == false ? branch!.value : "main",
                    stars: stars?.value ?? 0,
                    license: license?.value ?? "",
                    distribution: distribution?.value ?? "",
                    category: category?.value ?? "",
                    description: description?.value ?? ""
                )
            }

            /// Upstream records the path inconsistently: usually the skill directory, but
            /// sometimes the `SKILL.md` inside it. Both describe the same skill, and only the
            /// directory form can be installed — normalising here also collapses the pair
            /// into one search hit instead of two.
            static func skillDirectory(from path: String) -> String {
                var trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
                var components = trimmed.split(separator: "/").map(String.init)
                if components.last?.caseInsensitiveCompare(SkillManifest.fileName) == .orderedSame {
                    components.removeLast()
                }
                trimmed = components.joined(separator: "/")
                return trimmed
            }
        }

        var skills: [Entry]
    }

    /// The raw index bytes, for the fast line filter in `RegistryShardIndex`.
    public func loadRaw() throws -> Data {
        guard exists else { return Data() }
        return try Data(contentsOf: indexFile, options: .mappedIfSafe)
    }
}

// MARK: - Lenient scalars
//
// The registry is generated from 160k third-party repositories, and the field types are not
// enforced upstream: `description` arrives as a string for most records and as an array of
// strings for a handful. Failing the whole refresh over one malformed row would make the
// index unbuildable, so these decode whatever shape shows up and normalise it.

public struct LooseString: Decodable, Sendable {
    public var value: String

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([String].self) {
            value = array.joined(separator: " ")
        } else if let int = try? container.decode(Int.self) {
            value = String(int)
        } else if let double = try? container.decode(Double.self) {
            value = String(double)
        } else if let bool = try? container.decode(Bool.self) {
            value = String(bool)
        } else {
            value = ""
        }
    }
}

public struct LooseInt: Decodable, Sendable {
    public var value: Int

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = Int(double)
        } else if let string = try? container.decode(String.self) {
            value = Int(string) ?? 0
        } else {
            value = 0
        }
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
