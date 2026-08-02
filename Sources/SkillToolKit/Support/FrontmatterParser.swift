import Foundation
import Yams

/// Reads the YAML front matter out of a `SKILL.md`.
///
/// Front matter is optional and frequently malformed in the wild, so parsing never throws:
/// a file without usable front matter still yields a manifest named after its directory.
public enum FrontmatterParser {
    /// Splits a document into its front-matter block and the remaining body.
    public static func split(_ document: String) -> (frontmatter: String?, body: String) {
        // Tolerate a UTF-8 BOM and leading blank lines before the opening delimiter.
        var text = document
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let leading = text.drop { $0 == "\n" || $0 == "\r" }

        var lines = leading.components(separatedBy: .newlines)
        guard let first = lines.first, isDelimiter(first) else { return (nil, document) }
        lines.removeFirst()

        guard let closingIndex = lines.firstIndex(where: isDelimiter) else {
            // An unterminated block is not front matter.
            return (nil, document)
        }
        let frontmatter = lines[..<closingIndex].joined(separator: "\n")
        let body = lines[(closingIndex + 1)...].joined(separator: "\n")
        return (frontmatter, body)
    }

    /// Parses a `SKILL.md`, falling back to `fallbackName` when the front matter is absent
    /// or does not carry a usable `name`.
    public static func parse(document: String, fallbackName: String) -> SkillManifest {
        guard
            let frontmatter = split(document).frontmatter,
            let node = try? Yams.load(yaml: frontmatter),
            let mapping = node as? [String: Any]
        else {
            return SkillManifest(name: fallbackName)
        }

        var extras: [String: String] = [:]
        for (key, value) in mapping {
            guard let scalar = scalarString(value) else { continue }
            extras[key] = scalar
        }

        let name = extras.removeValue(forKey: "name")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = extras.removeValue(forKey: "description")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let license = extras.removeValue(forKey: "license")
        let version = extras.removeValue(forKey: "version")

        return SkillManifest(
            name: (name?.isEmpty ?? true) ? fallbackName : name!,
            description: (description?.isEmpty ?? true) ? nil : description,
            license: license,
            version: version,
            extras: extras
        )
    }

    public static func parse(fileAt url: URL, fallbackName: String) -> SkillManifest {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return SkillManifest(name: fallbackName)
        }
        return parse(document: text, fallbackName: fallbackName)
    }

    private static func isDelimiter(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces) == "---"
    }

    /// Flattens the scalar YAML types we care about; nested structures are skipped.
    private static func scalarString(_ value: Any) -> String? {
        switch value {
        case let string as String: string
        case let bool as Bool: String(bool)
        case let int as Int: String(int)
        case let double as Double: String(double)
        case let array as [Any]: array.compactMap(scalarString).joined(separator: ", ")
        default: nil
        }
    }
}
