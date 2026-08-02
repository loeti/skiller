import Foundation

public protocol SkillRegistry: Sendable {
    var origin: SkillSearchResult.Origin { get }
    func search(query: String, limit: Int) async throws -> [SkillSearchResult]
}

/// Results plus any non-fatal problems, so one unavailable registry does not fail the search.
public struct RegistrySearchOutcome: Sendable {
    public var results: [SkillSearchResult]
    public var warnings: [String]

    public init(results: [SkillSearchResult] = [], warnings: [String] = []) {
        self.results = results
        self.warnings = warnings
    }
}

public struct RegistryError: Error, CustomStringConvertible {
    public var registry: String
    public var reason: String

    public init(registry: String, reason: String) {
        self.registry = registry
        self.reason = reason
    }

    public var description: String { "\(registry): \(reason)" }
}

/// Small JSON-over-HTTP helper. Every registry we talk to is a plain GET returning JSON.
enum HTTPClient {
    static func getJSON<T: Decodable>(
        _ type: T.Type,
        url: URL,
        headers: [String: String] = [:],
        registryName: String,
        decoder: JSONDecoder = JSONDecoder()
    ) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("skill-tool/0.1", forHTTPHeaderField: "User-Agent")
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw RegistryError(registry: registryName, reason: "request failed — \(error.localizedDescription)")
        }

        guard let http = response as? HTTPURLResponse else {
            throw RegistryError(registry: registryName, reason: "unexpected non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw RegistryError(
                registry: registryName,
                reason: "HTTP \(http.statusCode)\(Self.rateLimitHint(http))"
            )
        }

        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw RegistryError(registry: registryName, reason: "could not decode response — \(error)")
        }
    }

    private static func rateLimitHint(_ response: HTTPURLResponse) -> String {
        guard response.statusCode == 403 || response.statusCode == 429 else { return "" }
        if let remaining = response.value(forHTTPHeaderField: "x-ratelimit-remaining"), remaining == "0" {
            return " (rate limit exhausted — set GITHUB_TOKEN or run `gh auth login`)"
        }
        return " (rate limited or unauthorized — set GITHUB_TOKEN or run `gh auth login`)"
    }
}
