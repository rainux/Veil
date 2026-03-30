import Foundation
import MessagePack

struct CellAttributes: Equatable, Sendable {
    var foreground: Int
    var background: Int
    var special: Int
    var bold: Bool
    var italic: Bool
    var underline: Bool
    var undercurl: Bool
    var underdouble: Bool
    var underdotted: Bool
    var underdashed: Bool
    var strikethrough: Bool
    var reverse: Bool
    var blend: Int

    nonisolated init(
        foreground: Int = -1,
        background: Int = -1,
        special: Int = -1,
        bold: Bool = false,
        italic: Bool = false,
        underline: Bool = false,
        undercurl: Bool = false,
        underdouble: Bool = false,
        underdotted: Bool = false,
        underdashed: Bool = false,
        strikethrough: Bool = false,
        reverse: Bool = false,
        blend: Int = 0
    ) {
        self.foreground = foreground
        self.background = background
        self.special = special
        self.bold = bold
        self.italic = italic
        self.underline = underline
        self.undercurl = undercurl
        self.underdouble = underdouble
        self.underdotted = underdotted
        self.underdashed = underdashed
        self.strikethrough = strikethrough
        self.reverse = reverse
        self.blend = blend
    }

    nonisolated init(from value: MessagePackValue) {
        var foreground = -1
        var background = -1
        var special = -1
        var bold = false
        var italic = false
        var underline = false
        var undercurl = false
        var underdouble = false
        var underdotted = false
        var underdashed = false
        var strikethrough = false
        var reverse = false
        var blend = 0

        if let dict = value.dictionaryValue {
            for (k, v) in dict {
                switch k.stringValue {
                case "foreground":
                    foreground = v.intValue
                case "background":
                    background = v.intValue
                case "special":
                    special = v.intValue
                case "bold":
                    bold = v.boolValue ?? false
                case "italic":
                    italic = v.boolValue ?? false
                case "underline":
                    underline = v.boolValue ?? false
                case "undercurl":
                    undercurl = v.boolValue ?? false
                case "underdouble":
                    underdouble = v.boolValue ?? false
                case "underdotted":
                    underdotted = v.boolValue ?? false
                case "underdashed":
                    underdashed = v.boolValue ?? false
                case "strikethrough":
                    strikethrough = v.boolValue ?? false
                case "reverse":
                    reverse = v.boolValue ?? false
                case "blend":
                    blend = v.intValue
                default:
                    break
                }
            }
        }

        self.foreground = foreground
        self.background = background
        self.special = special
        self.bold = bold
        self.italic = italic
        self.underline = underline
        self.undercurl = undercurl
        self.underdouble = underdouble
        self.underdotted = underdotted
        self.underdashed = underdashed
        self.strikethrough = strikethrough
        self.reverse = reverse
        self.blend = blend
    }

    nonisolated func effectiveForeground(defaultFg: Int, defaultBg: Int) -> Int {
        let fg = foreground >= 0 ? foreground : defaultFg
        let bg = background >= 0 ? background : defaultBg
        return reverse ? bg : fg
    }

    nonisolated func effectiveBackground(defaultFg: Int, defaultBg: Int) -> Int {
        let fg = foreground >= 0 ? foreground : defaultFg
        let bg = background >= 0 ? background : defaultBg
        return reverse ? fg : bg
    }
}
