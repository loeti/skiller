import Foundation

/// Searches the locally cached community registry — no network, no rate limit.
///
/// This is the only source that supplies a per-skill description *and* its licence, which is
/// why a hit here is worth more than a bare code-search match.
public struct RegistryShardIndex: SkillRegistry {
    public let origin = SkillSearchResult.Origin.registry
    private let cache: RegistryIndexCache

    public init(cache: RegistryIndexCache = RegistryIndexCache()) {
        self.cache = cache
    }

    public func search(query: String, limit: Int) async throws -> [SkillSearchResult] {
        guard cache.exists else {
            throw RegistryError(
                registry: origin.rawValue,
                reason: "no local index — run `skill-tool index --refresh` (~18 MB, once)"
            )
        }

        let terms = Self.tokenize(query)
        guard !terms.isEmpty else { return [] }

        let data: Data
        do {
            data = try cache.loadRaw()
        } catch {
            throw RegistryError(registry: origin.rawValue, reason: "could not read the index — \(error)")
        }

        let scored = Self.scan(data, terms: terms)
        return scored
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.record.stars > $1.record.stars
            }
            .prefix(limit)
            .compactMap { Self.makeResult($0.record) }
    }

    /// Looks one skill up by repository and directory name, for `info` on something that is
    /// installed (or named explicitly) rather than searched for.
    ///
    /// Returns `nil` when there is no local index — metadata is a bonus here, not a
    /// precondition, so this never throws for a missing cache.
    public func lookup(repo: String, skillName: String) -> RegistryRecord? {
        guard cache.exists, let data = try? cache.loadRaw() else { return nil }

        let needle = Array(repo.lowercased().utf8)
        var best: RegistryRecord?

        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.bindMemory(to: UInt8.self).baseAddress else { return }
            var lineStart = 0

            for index in 0...buffer.count {
                guard index == buffer.count || base[index] == 0x0A else { continue }
                defer { lineStart = index + 1 }
                let length = index - lineStart
                guard length > 0 else { continue }

                let line = UnsafeBufferPointer(start: base + lineStart, count: length)
                guard Self.containsCaseInsensitive(line, needle) else { continue }
                guard let record = Self.parse(String(decoding: line, as: UTF8.self)) else { continue }
                guard record.repo.caseInsensitiveCompare(repo) == .orderedSame else { continue }

                let directory = record.path.split(separator: "/").last.map(String.init) ?? record.path
                if directory.caseInsensitiveCompare(skillName) == .orderedSame {
                    best = record
                    return
                }
                // A name match is a weaker signal than the directory; keep looking.
                if best == nil, record.name.caseInsensitiveCompare(skillName) == .orderedSame {
                    best = record
                }
            }
        }
        return best
    }

    // MARK: - Scanning
    //
    // The index is ~43 MB of tab-separated lines. Decoding all of it into Strings costs well
    // over a second, which is far too slow for something that runs on every search. Instead
    // every line is first tested at the byte level against the rarest search term; only the
    // fraction that survives — typically well under 1% — is turned into a String and scored.
    // A record has to match *every* term to place, so filtering on one term first can never
    // drop a result that would have counted.

    static func scan(_ data: Data, terms: [String]) -> [(record: RegistryRecord, score: Int)] {
        // Longest term first: the longer the needle, the fewer incidental hits.
        let filterTerm = Array((terms.max(by: { $0.count < $1.count }) ?? terms[0]).utf8)
        var results: [(RegistryRecord, Int)] = []

        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.bindMemory(to: UInt8.self).baseAddress else { return }
            let count = buffer.count
            var lineStart = 0

            for index in 0...count {
                guard index == count || base[index] == 0x0A else { continue }
                defer { lineStart = index + 1 }
                let length = index - lineStart
                guard length > 0 else { continue }

                let line = UnsafeBufferPointer(start: base + lineStart, count: length)
                guard containsCaseInsensitive(line, filterTerm) else { continue }

                let text = String(decoding: line, as: UTF8.self)
                guard let record = parse(text) else { continue }
                let score = score(record, terms: terms)
                if score > 0 { results.append((record, score)) }
            }
        }

        return results
    }

    /// ASCII case-insensitive substring test. The registry's names and descriptions are
    /// predominantly ASCII; a non-ASCII needle simply never matches here, and the full
    /// `score` pass still handles it correctly for anything the filter lets through.
    static func containsCaseInsensitive(_ haystack: UnsafeBufferPointer<UInt8>, _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        let limit = haystack.count - needle.count

        outer: for start in 0...limit {
            for offset in 0..<needle.count {
                if lowercased(haystack[start + offset]) != needle[offset] { continue outer }
            }
            return true
        }
        return false
    }

    @inline(__always)
    static func lowercased(_ byte: UInt8) -> UInt8 {
        // 'A'...'Z'
        (byte >= 65 && byte <= 90) ? byte + 32 : byte
    }

    static func parse(_ line: String) -> RegistryRecord? {
        let fields = line.split(separator: RegistryIndexCache.separator, omittingEmptySubsequences: false)
        guard fields.count >= 9 else { return nil }
        return RegistryRecord(
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
    }

    // MARK: - Scoring

    static func tokenize(_ query: String) -> [String] {
        query
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    /// What matters most is whether *all* the terms are in the name.
    ///
    /// Scoring each term independently gets this wrong: for "swift concurrency", a skill
    /// simply called `swift` scores an exact hit on one term plus a description hit on the
    /// other, and outranks `swift-concurrency-expert`, which is obviously the better answer.
    /// The all-terms-in-name bonus is therefore larger than any single-term score.
    static func score(_ record: RegistryRecord, terms: [String]) -> Int {
        let name = record.name.lowercased()
        let description = record.description.lowercased()
        let category = record.category.lowercased()

        var score = 0
        var termsMatchedInName = 0

        for term in terms {
            if name == term {
                score += 60
                termsMatchedInName += 1
            } else if name.hasPrefix(term) {
                score += 40
                termsMatchedInName += 1
            } else if name.contains(term) {
                score += 30
                termsMatchedInName += 1
            } else if description.contains(term) {
                score += 5
            } else if category.contains(term) {
                score += 2
            } else {
                // Every term has to appear somewhere, or this is not a candidate.
                return 0
            }
        }

        if termsMatchedInName == terms.count { score += 150 }
        // The name *is* the query, modulo separators.
        if name.replacingOccurrences(of: "-", with: " ") == terms.joined(separator: " ") {
            score += 200
        }
        return score
    }

    static func makeResult(_ record: RegistryRecord) -> SkillSearchResult? {
        guard let ref = record.ref else { return nil }
        return SkillSearchResult(
            ref: ref,
            displayName: record.name.isEmpty ? ref.defaultInstallName : record.name,
            description: record.description.isEmpty ? nil : record.description,
            stars: record.stars > 0 ? record.stars : nil,
            license: record.license.isEmpty ? nil : record.license,
            distribution: record.distribution.isEmpty ? nil : record.distribution,
            category: record.category.isEmpty ? nil : record.category,
            origins: [.registry]
        )
    }
}
