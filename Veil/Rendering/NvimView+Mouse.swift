import AppKit

extension NvimView {
    override func mouseDown(with event: NSEvent) {
        sendMouseEvent(event, button: "left", action: "press")
    }
    override func mouseUp(with event: NSEvent) {
        sendMouseEvent(event, button: "left", action: "release")
    }
    override func mouseDragged(with event: NSEvent) {
        sendMouseEvent(event, button: "left", action: "drag")
    }
    override func rightMouseDown(with event: NSEvent) {
        sendMouseEvent(event, button: "right", action: "press")
    }
    override func rightMouseUp(with event: NSEvent) {
        sendMouseEvent(event, button: "right", action: "release")
    }
    override func rightMouseDragged(with event: NSEvent) {
        sendMouseEvent(event, button: "right", action: "drag")
    }
    override func scrollWheel(with event: NSEvent) {
        let position = gridPosition(for: convert(event.locationInWindow, from: nil))
        let modifier = modifierString(event.modifierFlags)

        if event.hasPreciseScrollingDeltas {
            // Trackpad: accumulate pixel deltas, convert to line count
            scrollDeltaY += event.scrollingDeltaY
            let lineHeight = cellSize.height
            let lines = Int(scrollDeltaY / lineHeight)
            if lines != 0 {
                scrollDeltaY -= CGFloat(lines) * lineHeight
                let action = lines > 0 ? "up" : "down"
                let absLines = abs(lines)
                Task {
                    // Only update mousescroll when line count changes
                    if absLines != self.lastScrollLines {
                        self.lastScrollLines = absLines
                        try? await channel?.command("set mousescroll=ver:\(absLines),hor:0")
                    }
                    await channel?.inputMouse(
                        button: "wheel", action: action, modifier: modifier, grid: 0,
                        row: position.row, col: position.col)
                }
            }
        } else {
            // Mouse wheel: discrete events
            let deltaY = event.scrollingDeltaY
            let deltaX = event.scrollingDeltaX
            if abs(deltaY) > abs(deltaX), deltaY != 0 {
                let action = deltaY > 0 ? "up" : "down"
                let count = max(1, Int(abs(deltaY)))
                Task {
                    try? await channel?.command("set mousescroll=ver:\(count),hor:0")
                    await channel?.inputMouse(
                        button: "wheel", action: action, modifier: modifier, grid: 0,
                        row: position.row, col: position.col)
                }
            } else if abs(deltaX) > 0 {
                let action = deltaX > 0 ? "left" : "right"
                let count = max(1, Int(abs(deltaX)))
                Task {
                    try? await channel?.command("set mousescroll=ver:0,hor:\(count)")
                    await channel?.inputMouse(
                        button: "wheel", action: action, modifier: modifier, grid: 0,
                        row: position.row, col: position.col)
                }
            }
        }
    }

    private func sendMouseEvent(_ event: NSEvent, button: String, action: String) {
        let point = convert(event.locationInWindow, from: nil)
        let position = gridPosition(for: point)
        let modifier = modifierString(event.modifierFlags)
        Task {
            await channel?.inputMouse(
                button: button, action: action, modifier: modifier, grid: 0, row: position.row,
                col: position.col)
        }
    }

    private func modifierString(_ flags: NSEvent.ModifierFlags) -> String {
        var parts: [String] = []
        if flags.contains(.shift) { parts.append("S") }
        if flags.contains(.control) { parts.append("C") }
        if flags.contains(.option) { parts.append("A") }
        if flags.contains(.command) { parts.append("D") }
        return parts.joined(separator: "-")
    }
}
