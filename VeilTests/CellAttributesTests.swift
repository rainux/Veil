import Testing
import MessagePack
@testable import Veil

@MainActor
struct CellAttributesTests {

    @Test func defaultAttributes() {
        let attr = CellAttributes()
        #expect(attr.foreground == -1)
        #expect(attr.background == -1)
        #expect(attr.special == -1)
        #expect(attr.bold == false)
        #expect(attr.italic == false)
        #expect(attr.reverse == false)
        #expect(attr.blend == 0)
    }

    @Test func effectiveColorsNormal() {
        let attr = CellAttributes(foreground: 0xFF0000, background: 0x00FF00)
        #expect(attr.effectiveForeground(defaultFg: 0xFFFFFF, defaultBg: 0x000000) == 0xFF0000)
        #expect(attr.effectiveBackground(defaultFg: 0xFFFFFF, defaultBg: 0x000000) == 0x00FF00)
    }

    @Test func effectiveColorsDefaultFallback() {
        let attr = CellAttributes()
        #expect(attr.effectiveForeground(defaultFg: 0x123456, defaultBg: 0xABCDEF) == 0x123456)
        #expect(attr.effectiveBackground(defaultFg: 0x123456, defaultBg: 0xABCDEF) == 0xABCDEF)
    }

    @Test func effectiveColorsReversed() {
        let attr = CellAttributes(foreground: 0xFF0000, background: 0x00FF00, reverse: true)
        #expect(attr.effectiveForeground(defaultFg: 0xFFFFFF, defaultBg: 0x000000) == 0x00FF00)
        #expect(attr.effectiveBackground(defaultFg: 0xFFFFFF, defaultBg: 0x000000) == 0xFF0000)
    }

    @Test func effectiveColorsReversedWithDefaults() {
        let attr = CellAttributes(reverse: true)
        #expect(attr.effectiveForeground(defaultFg: 0x111111, defaultBg: 0x222222) == 0x222222)
        #expect(attr.effectiveBackground(defaultFg: 0x111111, defaultBg: 0x222222) == 0x111111)
    }

    @Test func parseFromMessagePack() {
        let dict: [MessagePackValue: MessagePackValue] = [
            .string("foreground"): .uint(0xFF0000),
            .string("background"): .uint(0x00FF00),
            .string("bold"): .bool(true),
            .string("italic"): .bool(true),
            .string("reverse"): .bool(false),
            .string("blend"): .int(50),
        ]
        let attr = CellAttributes(from: .map(dict))
        #expect(attr.foreground == 0xFF0000)
        #expect(attr.background == 0x00FF00)
        #expect(attr.bold == true)
        #expect(attr.italic == true)
        #expect(attr.reverse == false)
        #expect(attr.blend == 50)
    }
}
