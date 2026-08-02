import Foundation

/// Queries several registries concurrently and folds their rows into one ranked list.
///
/// A registry that fails contributes a warning instead of aborting the search — GitHub code
/// search in particular is unavailable without a token and rate-limited with one.
public struct MergedRegistry: Sendable {
    private let registries: [any SkillRegistry]

    public init(registries: [any SkillRegistry]) {
        self.registries = registries
    }

    public init(origins: [SkillSearchResult.Origin]) {
        self.registries = origins.map { origin in
            switch origin {
            case .skillsSh: SkillsShRegistry() as any SkillRegistry
            case .gitHub: GitHubRegistry() as any SkillRegistry
            case .registry: RegistryShardIndex() as any SkillRegistry
            }
        }
    }

    public func search(query: String, limit: Int) async -> RegistrySearchOutcome {
        var lists: [[SkillSearchResult]] = []
        var warnings: [String] = []

        await withTaskGroup(of: Result<[SkillSearchResult], any Error>.self) { group in
            for registry in registries {
                group.addTask {
                    do {
                        // Ask each registry for the full limit; fusion decides what surfaces.
                        return .success(try await registry.search(query: query, limit: limit))
                    } catch {
                        return .failure(error)
                    }
                }
            }
            for await outcome in group {
                switch outcome {
                case .success(let results): lists.append(results)
                case .failure(let error): warnings.append(String(describing: error))
                }
            }
        }

        return RegistrySearchOutcome(
            results: Self.fuse(lists, limit: limit),
            warnings: warnings.sorted()
        )
    }

    /// How many rows a single repository may occupy before the rest are held back.
    ///
    /// Aggregator repositories mirror hundreds of skills each. Without a cap one of them
    /// takes over the result list — a search for "swift concurrency" returned 8 of 20 rows
    /// from a single mirror, crowding out the repositories the skills actually come from.
    public static let defaultPerRepoLimit = 3

    /// Reciprocal Rank Fusion.
    ///
    /// The registries score on incompatible scales — skills.sh reports install counts in the
    /// tens of thousands, while GitHub code search reports no popularity signal at all. Adding
    /// those numbers would bury every GitHub row. RRF throws the raw magnitudes away and uses
    /// only each row's *position* within its own list, so both registries contribute evenly and
    /// a skill found by both is pushed to the top.
    static func fuse(_ lists: [[SkillSearchResult]], limit: Int, k: Double = 60) -> [SkillSearchResult] {
        var merged: [String: SkillSearchResult] = [:]
        var scores: [String: Double] = [:]
        var firstSeen: [String: Int] = [:]
        var counter = 0

        for list in lists {
            for (position, result) in list.enumerated() {
                let id = result.id
                if let existing = merged[id] {
                    merged[id] = existing.merged(with: result)
                } else {
                    merged[id] = result
                    firstSeen[id] = counter
                    counter += 1
                }
                scores[id, default: 0] += 1 / (k + Double(position + 1))
            }
        }

        let ranked = merged.values
            .sorted { lhs, rhs in
                let lhsScore = scores[lhs.id] ?? 0
                let rhsScore = scores[rhs.id] ?? 0
                if lhsScore != rhsScore { return lhsScore > rhsScore }
                // Equal fusion score: prefer the more popular, then keep discovery order stable.
                if lhs.popularity != rhs.popularity { return lhs.popularity > rhs.popularity }
                return (firstSeen[lhs.id] ?? 0) < (firstSeen[rhs.id] ?? 0)
            }

        return capPerRepository(ranked, limit: limit)
    }

    /// Applies the per-repository cap, then backfills from what it held back so the caller
    /// still gets `limit` rows when the corpus simply is that concentrated.
    static func capPerRepository(
        _ ranked: [SkillSearchResult],
        limit: Int,
        perRepo: Int = MergedRegistry.defaultPerRepoLimit
    ) -> [SkillSearchResult] {
        var counts: [String: Int] = [:]
        var kept: [SkillSearchResult] = []
        var overflow: [SkillSearchResult] = []

        for result in ranked {
            let key = result.ref.repoSlug.lowercased()
            let seen = counts[key, default: 0]
            if seen < perRepo {
                counts[key] = seen + 1
                kept.append(result)
            } else {
                overflow.append(result)
            }
        }

        if kept.count < limit {
            kept.append(contentsOf: overflow.prefix(limit - kept.count))
        }
        return Array(kept.prefix(limit))
    }

    /// Folds rows describing the same skill together, keeping the richer fields.
    static func deduplicate(_ results: [SkillSearchResult]) -> [SkillSearchResult] {
        var byID: [String: SkillSearchResult] = [:]
        var order: [String] = []
        for result in results {
            if let existing = byID[result.id] {
                byID[result.id] = existing.merged(with: result)
            } else {
                byID[result.id] = result
                order.append(result.id)
            }
        }
        return order.compactMap { byID[$0] }
    }
}
