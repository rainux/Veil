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
        let deltaY = event.scrollingDeltaY
        let deltaX = event.scrollingDeltaX
        if abs(deltaY) > abs(deltaX) {
            let button = deltaY > 0 ? "wheel_up" : "wheel_down"
            let count = max(1, Int(abs(deltaY) / cellSize.height))
            let modifier = modifierString(event.modifierFlags)
            for _ in 0..<count {
                Task {
                    await channel?.inputMouse(button: button, action: "press", modifier: modifier, grid: 0, row: position.row, col: position.col)
                }
            }
        } else if abs(deltaX) > 0 {
            let button = deltaX > 0 ? "wheel_left" : "wheel_right"
            let modifier = modifierString(event.modifierFlags)
            Task {
                await channel?.inputMouse(button: button, action: "press", modifier: modifier, grid: 0, row: position.row, col: position.col)
            }
        }
    }

    private func sendMouseEvent(_ event: NSEvent, button: String, action: String) {
        let point = convert(event.locationInWindow, from: nil)
        let position = gridPosition(for: point)
        let modifier = modifierString(event.modifierFlags)
        Task {
            await channel?.inputMouse(button: button, action: action, modifier: modifier, grid: 0, row: position.row, col: position.col)
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
