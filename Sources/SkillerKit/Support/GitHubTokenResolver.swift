import Foundation

/// Finds a GitHub token without asking the user to configure one.
///
/// Order: `GITHUB_TOKEN`, `GH_TOKEN`, then `gh auth token` if the GitHub CLI is installed
/// and logged in. Returns `nil` when nothing is available — search still works unauthenticated,
/// just with a much lower rate limit and no code search.
public actor GitHubTokenResolver {
    public static let shared = GitHubTokenResolver()

    private var cached: String??

    public init() {}

    public func token() async -> String? {
        if let cached { return cached }
        let resolved = await Self.resolve()
        cached = resolved
        return resolved
    }

    private static func resolve() async -> String? {
        let environment = ProcessInfo.processInfo.environment
        for key in ["GITHUB_TOKEN", "GH_TOKEN"] {
            if let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }

        guard await ProcessRunner.isAvailable("gh") else { return nil }
        guard let result = try? await ProcessRunner.run("gh", ["auth", "token"]), result.succeeded else {
            return nil
        }
        let token = result.output
        return token.isEmpty ? nil : token
    }
}
