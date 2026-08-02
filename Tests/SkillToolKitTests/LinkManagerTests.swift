import Foundation
import Testing

@testable import SkillToolKit

@Suite("Relative symlinks")
struct LinkManagerTests {
    /// A throwaway directory tree, removed when the test finishes.
    struct Sandbox: ~Copyable {
        let root: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appending(path: "skill-tool-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        deinit {
            try? FileManager.default.removeItem(at: root)
        }

        func directory(_ path: String) throws -> URL {
            let url = root.appending(path: path, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        func path(_ path: String) -> URL {
            root.appending(path: path, directoryHint: .notDirectory)
        }
    }

    @Test("relative paths ascend and descend correctly")
    func computesRelativePaths() {
        let root = URL(filePath: "/w", directoryHint: .isDirectory)
        let installs = root.appending(path: "installs", directoryHint: .isDirectory)
        let target = root.appending(path: "downloads/github.com/o/r/skill", directoryHint: .isDirectory)
        #expect(LinkManager.relativePath(from: installs, to: target) == "../downloads/github.com/o/r/skill")

        let group = root.appending(path: "skills/swiftui", directoryHint: .isDirectory)
        let install = installs.appending(path: "my-skill", directoryHint: .notDirectory)
        #expect(LinkManager.relativePath(from: group, to: install) == "../../installs/my-skill")

        let nested = root.appending(path: "skills/vpbank/bkt", directoryHint: .isDirectory)
        #expect(LinkManager.relativePath(from: nested, to: install) == "../../../installs/my-skill")
    }

    @Test("a link to itself is '.'")
    func relativePathToSelf() {
        let url = URL(filePath: "/w/installs", directoryHint: .isDirectory)
        #expect(LinkManager.relativePath(from: url, to: url) == ".")
    }

    @Test("created links are relative and resolve to the target")
    func createsRelativeLink() throws {
        let sandbox = try Sandbox()
        let target = try sandbox.directory("downloads/repo/skill")
        let link = sandbox.path("installs/skill")

        try LinkManager.createLink(at: link, to: target)

        let destination = try FileManager.default.destinationOfSymbolicLink(
            atPath: link.path(percentEncoded: false)
        )
        #expect(destination == "../downloads/repo/skill")
        #expect(LinkManager.state(of: link, expectedTarget: target) == .correct)
    }

    @Test("creating the same link twice is a no-op")
    func isIdempotent() throws {
        let sandbox = try Sandbox()
        let target = try sandbox.directory("downloads/repo/skill")
        let link = sandbox.path("installs/skill")

        try LinkManager.createLink(at: link, to: target)
        try LinkManager.createLink(at: link, to: target)
        #expect(LinkManager.state(of: link, expectedTarget: target) == .correct)
    }

    @Test("a link pointing elsewhere is reported and only replaced on request")
    func detectsWrongTarget() throws {
        let sandbox = try Sandbox()
        let first = try sandbox.directory("downloads/repo/one")
        let second = try sandbox.directory("downloads/repo/two")
        let link = sandbox.path("installs/skill")

        try LinkManager.createLink(at: link, to: first)
        guard case .wrongTarget = LinkManager.state(of: link, expectedTarget: second) else {
            Issue.record("expected wrongTarget")
            return
        }
        #expect(throws: LinkManager.LinkError.self) {
            try LinkManager.createLink(at: link, to: second)
        }
        try LinkManager.createLink(at: link, to: second, replaceExisting: true)
        #expect(LinkManager.state(of: link, expectedTarget: second) == .correct)
    }

    @Test("a dangling link is detected and replaced without asking")
    func repairsBrokenLink() throws {
        let sandbox = try Sandbox()
        let target = try sandbox.directory("downloads/repo/skill")
        let link = sandbox.path("installs/skill")
        try LinkManager.createLink(at: link, to: target)

        try FileManager.default.removeItem(at: target)
        guard case .broken = LinkManager.state(of: link, expectedTarget: target) else {
            Issue.record("expected broken")
            return
        }

        _ = try sandbox.directory("downloads/repo/skill")
        try LinkManager.createLink(at: link, to: target)
        #expect(LinkManager.state(of: link, expectedTarget: target) == .correct)
    }

    @Test("a real directory is never silently replaced")
    func refusesToClobberRealDirectory() throws {
        let sandbox = try Sandbox()
        let target = try sandbox.directory("downloads/repo/skill")
        let occupied = try sandbox.directory("installs/skill")

        #expect(LinkManager.state(of: occupied, expectedTarget: target) == .occupiedByRealPath)
        #expect(throws: LinkManager.LinkError.self) {
            try LinkManager.createLink(at: occupied, to: target, replaceExisting: true)
        }
        #expect(FileManager.default.fileExists(atPath: occupied.path(percentEncoded: false)))
    }

    @Test("removeLink refuses to delete real content")
    func refusesToRemoveRealDirectory() throws {
        let sandbox = try Sandbox()
        let real = try sandbox.directory("installs/skill")
        #expect(throws: LinkManager.LinkError.self) {
            try LinkManager.removeLink(at: real)
        }
        #expect(FileManager.default.fileExists(atPath: real.path(percentEncoded: false)))
    }

    @Test("symlinks(in:) lists only links, sorted")
    func listsOnlySymlinks() throws {
        let sandbox = try Sandbox()
        let target = try sandbox.directory("downloads/repo/skill")
        let group = try sandbox.directory("skills/group")
        _ = try sandbox.directory("skills/group/real-directory")
        try LinkManager.createLink(at: group.appending(path: "b", directoryHint: .notDirectory), to: target)
        try LinkManager.createLink(at: group.appending(path: "a", directoryHint: .notDirectory), to: target)

        let names = LinkManager.symlinks(in: group).map(\.lastPathComponent)
        #expect(names == ["a", "b"])
    }
}
