import Foundation
import Testing

@testable import SkillerKit

@Suite("SKILL.md front matter")
struct FrontmatterParserTests {
    @Test("name and description are lifted out of the YAML block")
    func parsesBasicFields() {
        let document = """
            ---
            name: swiftui-pro
            description: Reviews SwiftUI code for best practices.
            license: MIT
            ---

            # Body
            """
        let manifest = FrontmatterParser.parse(document: document, fallbackName: "fallback")
        #expect(manifest.name == "swiftui-pro")
        #expect(manifest.description == "Reviews SwiftUI code for best practices.")
        #expect(manifest.license == "MIT")
    }

    @Test("a multi-line folded description is joined")
    func parsesFoldedDescription() {
        let document = """
            ---
            name: x
            description: >
              Use when writing SwiftUI code,
              including state management.
            ---
            """
        let manifest = FrontmatterParser.parse(document: document, fallbackName: "fallback")
        #expect(manifest.description?.contains("state management") == true)
    }

    @Test("a document without front matter falls back to the directory name")
    func fallsBackWithoutFrontmatter() {
        let manifest = FrontmatterParser.parse(document: "# Just a heading\n", fallbackName: "my-skill")
        #expect(manifest.name == "my-skill")
        #expect(manifest.description == nil)
    }

    @Test("an unterminated block is not treated as front matter")
    func ignoresUnterminatedBlock() {
        let document = """
            ---
            name: never-closed
            """
        let manifest = FrontmatterParser.parse(document: document, fallbackName: "my-skill")
        #expect(manifest.name == "my-skill")
    }

    @Test("broken YAML does not throw and does not lose the fallback name")
    func toleratesBrokenYAML() {
        let document = """
            ---
            name: [unclosed
            ---
            body
            """
        let manifest = FrontmatterParser.parse(document: document, fallbackName: "my-skill")
        #expect(manifest.name == "my-skill")
    }

    @Test("an empty name falls back rather than producing a nameless skill")
    func rejectsEmptyName() {
        let document = """
            ---
            name: ""
            description: something
            ---
            """
        let manifest = FrontmatterParser.parse(document: document, fallbackName: "my-skill")
        #expect(manifest.name == "my-skill")
        #expect(manifest.description == "something")
    }

    @Test("non-scalar entries are skipped, remaining scalars land in extras")
    func collectsExtras() {
        let document = """
            ---
            name: x
            allowed-tools: Read, Bash
            nested:
              key: value
            ---
            """
        let manifest = FrontmatterParser.parse(document: document, fallbackName: "x")
        #expect(manifest.extras["allowed-tools"] == "Read, Bash")
        #expect(manifest.extras["nested"] == nil)
    }

    @Test("a leading BOM does not hide the front matter")
    func toleratesBOM() {
        let document = "\u{FEFF}---\nname: bom-skill\n---\n"
        let manifest = FrontmatterParser.parse(document: document, fallbackName: "fallback")
        #expect(manifest.name == "bom-skill")
    }
}
