import AppKit
import MessagePack

// MARK: - Keyboard handling

extension NvimView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command),
            let chars = event.charactersIgnoringModifiers
        else {
            return super.performKeyEquivalent(with: event)
        }

        // Cmd+1-9: tab switching
        if let digit = chars.first?.wholeNumberValue, digit >= 1 && digit <= 9 {
            let cmd = digit == 9 ? "tablast" : "tabnext \(digit)"
            Task { try? await channel?.command(cmd) }
            return true
        }

        // Cmd+Ctrl combinations: pass to system (e.g. Cmd+Ctrl+F for Full Screen)
        if event.modifierFlags.contains(.control) {
            return super.performKeyEquivalent(with: event)
        }

        // Let system handle these Cmd+key combos
        let systemKeys: Set<String> = [
            "q", "n", "h", "m", ",", "z", "x", "c", "v", "a", "`", "s", "w",
        ]
        if systemKeys.contains(chars.lowercased()) {
            return super.performKeyEquivalent(with: event)
        }

        // Everything else goes to nvim as <D-key>
        let nvimKey = KeyUtils.nvimKey(characters: chars, modifiers: event.modifierFlags)
        Task { await channel?.send(key: nvimKey) }
        return true
    }

    override func keyDown(with event: NSEvent) {
        // When composing (marked text active), all keys go through IME
        // so backspace shortens the pinyin, Enter confirms, Esc cancels, etc.
        if markedText != nil {
            inputContext?.handleEvent(event)
            return
        }

        let modifiers = event.modifierFlags.intersection([.control, .option, .command])
        if !modifiers.isEmpty {
            sendKeyDirectly(event)
            return
        }

        // Special keys bypass IME — they would otherwise be consumed by doCommand(by:)
        if let chars = event.characters, let scalar = chars.unicodeScalars.first {
            let code = Int(scalar.value)
            if code == 0x1B || code == 0x0D || code == 0x09 || code == 0x7F
                || code == 0x19 || (code >= 0xF700 && code <= 0xF8FF)
            {
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
        let modifiers = event.modifierFlags.intersection([.control, .option, .command])
        let chars: String?
        if !modifiers.isEmpty {
            chars = event.charactersIgnoringModifiers
        } else {
            chars = event.characters
        }
        guard let characters = chars, !characters.isEmpty else { return }
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
        let screenScale = window?.backingScaleFactor ?? 2.0

        let charCount = text.count
        let width = cellSize.width * CGFloat(charCount)
        let height = cellSize.height

        let pixelWidth = Int(ceil(width * screenScale))
        let pixelHeight = Int(ceil(height * screenScale))
        guard pixelWidth > 0, pixelHeight > 0 else { return }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard
            let ctx = CGContext(
                data: nil, width: pixelWidth, height: pixelHeight,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return }

        ctx.scaleBy(x: screenScale, y: screenScale)

        // Fill background
        ctx.setFillColor(NSColor(rgb: defaultBg).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Render each character using GlyphCache (same pipeline as grid)
        let attrs = CellAttributes()
        for (i, char) in text.enumerated() {
            let x = CGFloat(i) * cellSize.width
            let cellRect = CGRect(x: x, y: 0, width: cellSize.width, height: height)
            let glyphImage = glyphCache.get(
                text: String(char), attrs: attrs,
                defaultFg: defaultFg, defaultBg: defaultBg, cellCount: 1
            )
            ctx.draw(glyphImage, in: cellRect)
        }

        // Draw underline at bottom
        let underlineY: CGFloat = 1.5
        ctx.setStrokeColor(NSColor(rgb: defaultFg).cgColor)
        ctx.setLineWidth(1.0)
        ctx.move(to: CGPoint(x: 0, y: underlineY))
        ctx.addLine(to: CGPoint(x: width, y: underlineY))
        ctx.strokePath()

        guard let image = ctx.makeImage() else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        markedLayer.contents = image
        markedLayer.contentsScale = screenScale
        markedLayer.frame = CGRect(
            x: cursorFrame.origin.x,
            y: cursorFrame.origin.y,
            width: width,
            height: height
        )
        markedLayer.isHidden = false
        CATransaction.commit()
    }

    func clearMarkedText() {
        markedText = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        markedLayer.isHidden = true
        markedLayer.contents = nil
        CATransaction.commit()
    }
    // MARK: - Debug Overlay

    @objc func toggleDebugOverlay(_ sender: Any?) {
        debugOverlayEnabled.toggle()
        delegate?.nvimViewNeedsDisplay(self)
    }

    // MARK: - Standard File actions

    @objc func saveDocument(_ sender: Any?) {
        Task { try? await channel?.command("w") }
    }

    @objc func closeTabOrWindow(_ sender: Any?) {
        Task {
            guard let channel else { return }
            let (_, result) = await channel.request(
                "nvim_eval", params: [.string("tabpagenr('$')")])
            let tabCount = result.intValue
            if tabCount > 1 {
                try? await channel.command("tabclose")
            } else {
                await MainActor.run {
                    self.window?.performClose(nil)
                }
            }
        }
    }

    @objc func closeWindow(_ sender: Any?) {
        window?.performClose(nil)
    }

    // MARK: - Standard Edit actions

    @objc func undo(_ sender: Any?) {
        Task { await channel?.send(key: "u") }
    }

    @objc func redo(_ sender: Any?) {
        Task { await channel?.send(key: "<C-r>") }
    }

    @objc func cut(_ sender: Any?) {
        Task { await channel?.send(key: "\"+d") }
    }

    @objc func copy(_ sender: Any?) {
        Task { await channel?.send(key: "\"+y") }
    }

    @objc func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        Task {
            _ = await channel?.request(
                "nvim_paste", params: [.string(text), .bool(true), .int(-1)])
        }
    }

    override func selectAll(_ sender: Any?) {
        Task { await channel?.send(key: "ggVG") }
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
            markedPosition = gridPosition(
                for: NSPoint(
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

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?)
        -> NSAttributedString?
    {
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
