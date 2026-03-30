import AppKit

nonisolated enum KeyUtils {
    static func nvimKey(characters: String, modifiers: NSEvent.ModifierFlags) -> String {
        guard let scalar = characters.unicodeScalars.first else { return "" }
        let code = Int(scalar.value)

        if let name = specialKeyName(code) {
            return wrapWithModifiers(name, modifiers: modifiers)
        }
        if code == 0x1B { return wrapWithModifiers("Esc", modifiers: modifiers) }
        if code == 0x7F { return wrapWithModifiers("BS", modifiers: modifiers) }
        if code == 0x09 { return wrapWithModifiers("Tab", modifiers: modifiers) }
        if code == 0x0D { return wrapWithModifiers("CR", modifiers: modifiers) }
        if code == 0x20 { return wrapWithModifiers("Space", modifiers: modifiers) }
        if characters == "<" { return wrapWithModifiers("lt", modifiers: modifiers) }
        if characters == "\\" { return wrapWithModifiers("Bslash", modifiers: modifiers) }

        let relevantModifiers = modifiers.intersection([.control, .option, .command, .shift])
        if relevantModifiers.isEmpty { return characters }
        return wrapWithModifiers(characters, modifiers: modifiers)
    }

    private static func wrapWithModifiers(_ key: String, modifiers: NSEvent.ModifierFlags) -> String {
        var prefix = ""
        if modifiers.contains(.control) { prefix += "C-" }
        if modifiers.contains(.shift) { prefix += "S-" }
        if modifiers.contains(.option) { prefix += "M-" }
        if modifiers.contains(.command) { prefix += "D-" }
        if prefix.isEmpty && key.count == 1 && !isNamedKey(key) { return key }
        return "<\(prefix)\(key)>"
    }

    private static func isNamedKey(_ key: String) -> Bool {
        ["lt", "Bslash", "Space", "CR", "Tab", "Esc", "BS"].contains(key)
    }

    private static func specialKeyName(_ code: Int) -> String? { specialKeys[code] }

    private static let specialKeys: [Int: String] = {
        var map: [Int: String] = [
            NSUpArrowFunctionKey: "Up",
            NSDownArrowFunctionKey: "Down",
            NSLeftArrowFunctionKey: "Left",
            NSRightArrowFunctionKey: "Right",
            NSInsertFunctionKey: "Insert",
            NSDeleteFunctionKey: "Del",
            NSHomeFunctionKey: "Home",
            NSEndFunctionKey: "End",
            NSPageUpFunctionKey: "PageUp",
            NSPageDownFunctionKey: "PageDown",
        ]
        for i in 0..<35 { map[NSF1FunctionKey + i] = "F\(i + 1)" }
        return map
    }()
}
