import Testing
@testable import Veil

struct CliArgParserTests {
    @Test func rendererOnly() {
        let result = CliArgParser.parse(["/path/to/Veil", "--veil-renderer", "coretext"])
        #expect(result.renderer == .coretext)
        #expect(result.nvimArgs.isEmpty)
    }

    @Test func rendererWithFile() {
        let result = CliArgParser.parse([
            "/path/to/Veil", "--veil-renderer", "coretext", "README.md",
        ])
        #expect(result.renderer == .coretext)
        #expect(result.nvimArgs == ["README.md"])
    }

    @Test func rendererAfterFile() {
        let result = CliArgParser.parse([
            "/path/to/Veil", "README.md", "--veil-renderer", "coretext",
        ])
        #expect(result.renderer == .coretext)
        #expect(result.nvimArgs == ["README.md"])
    }

    @Test func defaultRenderer() {
        let result = CliArgParser.parse(["/path/to/Veil", "file.txt"])
        #expect(result.renderer == .metal)
        #expect(result.nvimArgs == ["file.txt"])
    }

    @Test func rendererCaseInsensitive() {
        let result = CliArgParser.parse(["/path/to/Veil", "--veil-renderer", "CoreText"])
        #expect(result.renderer == .coretext)
    }

    @Test func rendererMetalExplicit() {
        let result = CliArgParser.parse(["/path/to/Veil", "--veil-renderer", "metal"])
        #expect(result.renderer == .metal)
    }

    @Test func filtersAppleArgs() {
        let result = CliArgParser.parse([
            "/path/to/Veil",
            "-NSDocumentRevisionsDebugMode", "YES",
            "-ApplePersistenceIgnoreState", "YES",
            "file.txt",
        ])
        #expect(result.nvimArgs == ["file.txt"])
        #expect(result.renderer == .metal)
    }

    @Test func filtersAppleArgsWithRenderer() {
        let result = CliArgParser.parse([
            "/path/to/Veil",
            "-NSDocumentRevisionsDebugMode", "YES",
            "--veil-renderer", "coretext",
            "file.txt",
        ])
        #expect(result.renderer == .coretext)
        #expect(result.nvimArgs == ["file.txt"])
    }

    @Test func multipleFiles() {
        let result = CliArgParser.parse([
            "/path/to/Veil", "--veil-renderer", "coretext",
            "file1.txt", "file2.txt", "file3.txt",
        ])
        #expect(result.renderer == .coretext)
        #expect(result.nvimArgs == ["file1.txt", "file2.txt", "file3.txt"])
    }

    @Test func nvimFlags() {
        let result = CliArgParser.parse(["/path/to/Veil", "-d", "file1.txt", "file2.txt"])
        #expect(result.renderer == .metal)
        #expect(result.nvimArgs == ["-d", "file1.txt", "file2.txt"])
    }

    @Test func rendererWithNvimFlags() {
        let result = CliArgParser.parse([
            "/path/to/Veil", "--veil-renderer", "coretext",
            "-d", "file1.txt", "file2.txt",
        ])
        #expect(result.renderer == .coretext)
        #expect(result.nvimArgs == ["-d", "file1.txt", "file2.txt"])
    }

    @Test func emptyArgs() {
        let result = CliArgParser.parse(["/path/to/Veil"])
        #expect(result.renderer == .metal)
        #expect(result.nvimArgs.isEmpty)
    }

    @Test func rendererMissingValue() {
        let result = CliArgParser.parse(["/path/to/Veil", "--veil-renderer"])
        #expect(result.renderer == .metal)
        #expect(result.nvimArgs.isEmpty)
    }
}
