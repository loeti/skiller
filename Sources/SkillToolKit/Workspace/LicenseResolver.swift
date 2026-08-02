import Foundation

/// Works out what licence applies to an installed skill, and says where that answer came from.
///
/// The three available signals disagree often enough that recording only one would be
/// misleading, so precedence is explicit: what the skill declares about itself beats a
/// third-party classification of its repository, which in turn beats the mere presence of a
/// licence file. Nothing here infers an SPDX identifier from licence *text* — a wrong
/// identifier is worse than an honest "unclear".
public enum LicenseResolver {
    public struct Resolution: Sendable, Equatable {
        public var license: String?
        public var source: LicenseSource?
        public var distribution: String?
        public var licenseFile: String?

        public init(
            license: String? = nil,
            source: LicenseSource? = nil,
            distribution: String? = nil,
            licenseFile: String? = nil
        ) {
            self.license = license
            self.source = source
            self.distribution = distribution
            self.licenseFile = licenseFile
        }
    }

    /// Filenames GitHub itself treats as licence files.
    static let licenseFileNames = [
        "LICENSE", "LICENSE.md", "LICENSE.txt", "LICENCE", "LICENCE.md", "LICENCE.txt",
        "COPYING", "COPYING.md", "UNLICENSE",
    ]

    public static func resolve(
        manifest: SkillManifest?,
        registry: RegistryRecord?,
        repositoryDirectory: URL?
    ) -> Resolution {
        var resolution = Resolution()

        // The registry's classification is recorded regardless of which value wins, because
        // `restricted` is a useful flag even when the skill declares a licence itself.
        if let distribution = registry?.distribution, !distribution.isEmpty {
            resolution.distribution = distribution
        }
        if let directory = repositoryDirectory {
            resolution.licenseFile = licenseFile(in: directory)
        }

        if let declared = manifest?.license, !declared.isEmpty {
            resolution.license = declared
            resolution.source = .manifest
            return resolution
        }

        if let classified = registry?.license, !classified.isEmpty {
            resolution.license = classified
            resolution.source = .registry
            return resolution
        }

        if let file = resolution.licenseFile {
            // A file exists but nothing identifies it — say exactly that.
            resolution.license = "unidentified (\(file))"
            resolution.source = .repositoryFile
        }
        return resolution
    }

    static func licenseFile(in directory: URL) -> String? {
        let fileManager = FileManager.default
        for name in licenseFileNames {
            let candidate = directory.appending(path: name, directoryHint: .notDirectory)
            if fileManager.fileExists(atPath: candidate.path(percentEncoded: false)) {
                return name
            }
        }
        return nil
    }
}
