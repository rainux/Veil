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
        if let frameString = UserDefaults.standard.string(forKey: "MacNeovimWindowFrame") {
            window.setFrame(NSRectFromString(frameString), display: false)
        }
        window.isReleasedWhenClosed = false
        window.restorationClass = nil
        window.isRestorable = false
        let toolbar = NSToolbar()
        toolbar.showsBaselineSeparator = false
        window.toolbar = toolbar
        self.init(window: window)
        window.delegate = self

        window.contentView = nvimView
        window.makeFirstResponder(nvimView)
    }

    func windowDidResize(_ notification: Notification) {
        saveWindowFrame()
        guard let contentSize = window?.contentView?.bounds.size else { return }
        (document as? WindowDocument)?.windowDidResize(to: contentSize)
    }

    func windowDidMove(_ notification: Notification) {
        saveWindowFrame()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        window?.makeFirstResponder(nvimView)
    }

    private func saveWindowFrame() {
        guard let frame = window?.frame else { return }
        UserDefaults.standard.set(NSStringFromRect(frame), forKey: "MacNeovimWindowFrame")
    }
}
