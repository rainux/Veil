import XCTest
import Carbon.HIToolbox
@testable import MacNeovim

final class KeyUtilsTests: XCTestCase {
    func testPlainCharacter() {
        XCTAssertEqual(KeyUtils.nvimKey(characters: "a", modifiers: []), "a")
        XCTAssertEqual(KeyUtils.nvimKey(characters: "Z", modifiers: []), "Z")
    }
    func testSpecialCharactersEscaped() {
        XCTAssertEqual(KeyUtils.nvimKey(characters: "<", modifiers: []), "<lt>")
        XCTAssertEqual(KeyUtils.nvimKey(characters: "\\", modifiers: []), "<Bslash>")
    }
    func testEnterKey() { XCTAssertEqual(KeyUtils.nvimKey(characters: "\r", modifiers: []), "<CR>") }
    func testEscapeKey() { XCTAssertEqual(KeyUtils.nvimKey(characters: "\u{1B}", modifiers: []), "<Esc>") }
    func testBackspace() { XCTAssertEqual(KeyUtils.nvimKey(characters: "\u{7F}", modifiers: []), "<BS>") }
    func testTab() { XCTAssertEqual(KeyUtils.nvimKey(characters: "\t", modifiers: []), "<Tab>") }
    func testSpace() { XCTAssertEqual(KeyUtils.nvimKey(characters: " ", modifiers: []), "<Space>") }
    func testArrowKeys() {
        let up = String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))
        XCTAssertEqual(KeyUtils.nvimKey(characters: up, modifiers: []), "<Up>")
        let down = String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))
        XCTAssertEqual(KeyUtils.nvimKey(characters: down, modifiers: []), "<Down>")
    }
    func testFunctionKeys() {
        let f1 = String(Character(UnicodeScalar(NSF1FunctionKey)!))
        XCTAssertEqual(KeyUtils.nvimKey(characters: f1, modifiers: []), "<F1>")
    }
    func testControlModifier() { XCTAssertEqual(KeyUtils.nvimKey(characters: "a", modifiers: .control), "<C-a>") }
    func testAltModifier() { XCTAssertEqual(KeyUtils.nvimKey(characters: "x", modifiers: .option), "<M-x>") }
    func testCmdModifier() { XCTAssertEqual(KeyUtils.nvimKey(characters: "s", modifiers: .command), "<D-s>") }
    func testMultipleModifiers() { XCTAssertEqual(KeyUtils.nvimKey(characters: "a", modifiers: [.control, .shift]), "<C-S-a>") }
    func testControlWithSpecialKey() {
        let up = String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))
        XCTAssertEqual(KeyUtils.nvimKey(characters: up, modifiers: .control), "<C-Up>")
    }
}
