import AppKit

// MARK: - Keyboard handling

extension NvimView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command),
              let chars = event.charactersIgnoringModifiers,
              let digit = chars.first?.wholeNumberValue,
              digit >= 1 && digit <= 9 else {
            return super.performKeyEquivalent(with: event)
        }
        let cmd = digit == 9 ? "tablast" : "tabnext \(digit)"
        Task { try? await channel?.command(cmd) }
        return true
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.control, .option, .command])
        if !modifiers.isEmpty {
            sendKeyDirectly(event)
            return
        }

        // Special keys bypass IME — they would otherwise be consumed by doCommand(by:)
        if let chars = event.characters, let scalar = chars.unicodeScalars.first {
            let code = Int(scalar.value)
            if code == 0x1B || code == 0x0D || code == 0x09 || code == 0x7F
                || code == 0x19 || (code >= 0xF700 && code <= 0xF8FF) {
                sendKeyDirectly(event)
                return
            }
        }

        // Normal text goes through IME
        keyDownDone = false
        inputContext?.handleEvent(event)
        if !keyDownDone && markedText == nil {
            sendKeyDirectly(event)
            keyDownDone = true
        }
    }

    private func sendKeyDirectly(_ event: NSEvent) {
        guard let characters = event.characters else { return }
        let nvimKey = KeyUtils.nvimKey(characters: characters, modifiers: event.modifierFlags)
        guard !nvimKey.isEmpty else { return }
        Task { await channel?.send(key: nvimKey) }
    }

    func updateMarkedTextDisplay() {
        guard let text = markedText, !text.isEmpty else {
            clearMarkedText()
            return
        }

        let cursorFrame = cursorLayer.frame

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        markedTextLayer.string = text
        markedTextLayer.font = gridFont
        markedTextLayer.fontSize = gridFont.pointSize

        // Size the layer to fit the text
        let width = CGFloat(text.count) * cellSize.width + 4
        let height = cellSize.height + 2
        markedTextLayer.frame = CGRect(
            x: cursorFrame.origin.x,
            y: cursorFrame.origin.y,
            width: width,
            height: height
        )
        markedTextLayer.isHidden = false

        CATransaction.commit()
    }

    func clearMarkedText() {
        markedText = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        markedTextLayer.isHidden = true
        markedTextLayer.string = nil
        CATransaction.commit()
    }
}

// MARK: - NSTextInputClient

extension NvimView: NSTextInputClient {
    func insertText(_ string: Any, replacementRange: NSRange) {
        keyDownDone = true
        clearMarkedText()

        let text: String
        if let attrString = string as? NSAttributedString {
            text = attrString.string
        } else if let str = string as? String {
            text = str
        } else {
            return
        }

        // Send each character as a Neovim key
        for char in text {
            let nvimKey = KeyUtils.nvimKey(characters: String(char), modifiers: [])
            Task { await channel?.send(key: nvimKey) }
        }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let text: String
        if let attrString = string as? NSAttributedString {
            text = attrString.string
        } else if let str = string as? String {
            text = str
        } else {
            return
        }

        if text.isEmpty {
            clearMarkedText()
        } else {
            markedText = text
            // Capture cursor position when composition begins
            markedPosition = gridPosition(for: NSPoint(
                x: cursorLayer.frame.origin.x,
                y: cursorLayer.frame.origin.y + cellSize.height / 2
            ))
            updateMarkedTextDisplay()
        }
    }

    func unmarkText() {
        clearMarkedText()
        inputContext?.discardMarkedText()
    }

    func selectedRange() -> NSRange {
        NSRange(location: NSNotFound, length: 0)
    }

    func markedRange() -> NSRange {
        guard let text = markedText else {
            return NSRange(location: NSNotFound, length: 0)
        }
        return NSRange(location: 0, length: text.utf16.count)
    }

    func hasMarkedText() -> Bool {
        markedText != nil
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        nil
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        // Return the cursor position in screen coordinates for IME candidate window
        guard let windowObj = window else { return .zero }
        let cursorFrame = cursorLayer.frame
        let viewRect = convert(cursorFrame, to: nil)
        return windowObj.convertToScreen(viewRect)
    }

    func characterIndex(for point: NSPoint) -> Int {
        let viewPoint = convert(point, from: nil)
        let pos = gridPosition(for: viewPoint)

        guard pos.row >= 0, pos.row < flatCharIndices.count else {
            return NSNotFound
        }
        let rowIndices = flatCharIndices[pos.row]
        guard pos.col >= 0, pos.col < rowIndices.count else {
            return NSNotFound
        }
        return rowIndices[pos.col]
    }

    override func doCommand(by selector: Selector) {
        keyDownDone = true
        // Most commands are handled by Neovim
    }
}
