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

        let container = NSView(frame: window.contentView!.bounds)
        container.autoresizingMask = [.width, .height]
        nvimView.translatesAutoresizingMaskIntoConstraints = false
        tablineView.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(tablineView)
        container.addSubview(nvimView)

        NSLayoutConstraint.activate([
            tablineView.topAnchor.constraint(equalTo: container.topAnchor),
            tablineView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tablineView.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            nvimView.topAnchor.constraint(equalTo: tablineView.bottomAnchor),
            nvimView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            nvimView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            nvimView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        window.contentView = container
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
