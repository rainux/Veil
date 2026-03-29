import AppKit

class WindowController: NSWindowController, NSWindowDelegate {
    let nvimView = NvimView(frame: .zero)
    let tablineView = TablineView(frame: .zero)

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "MacNeovim"
        window.center()
        window.setFrameAutosaveName("MacNeovimWindow")
        window.isReleasedWhenClosed = false
        window.restorationClass = nil
        window.isRestorable = false
        self.init(window: window)
        window.delegate = self

        window.contentView = nvimView
        window.makeFirstResponder(nvimView)
    }

    func windowDidResize(_ notification: Notification) {
        guard let contentSize = window?.contentView?.bounds.size else { return }
        (document as? WindowDocument)?.windowDidResize(to: contentSize)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        window?.makeFirstResponder(nvimView)
    }
}
