import AppKit
import MessagePack

class WindowController: NSWindowController, NSWindowDelegate {
    let nvimView = NvimView(frame: .zero)
    let tablineView = TablineView(frame: .zero)
    private(set) var customTitleLabel: NSTextField?

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.title = "Veil"
        window.center()
        if let frameString = UserDefaults.standard.string(forKey: "VeilWindowFrame") {
            window.setFrame(NSRectFromString(frameString), display: false)
        }
        window.isReleasedWhenClosed = false
        window.restorationClass = nil
        window.isRestorable = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(rgb: 0x1e1e1e)

        self.init(window: window)
        window.delegate = self

        let titleLabel = NSTextField(labelWithString: "Veil")
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .titleBarFont(ofSize: 0)
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingTail

        let container = NSView()
        container.wantsLayer = true
        container.translatesAutoresizingMaskIntoConstraints = false
        nvimView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(titleLabel)
        container.addSubview(nvimView)
        window.contentView = container

        let titleBarHeight: CGFloat = 28
        NSLayoutConstraint.activate([
            titleLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: container.topAnchor, constant: titleBarHeight / 2),
            titleLabel.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -160),

            nvimView.topAnchor.constraint(equalTo: container.topAnchor, constant: titleBarHeight),
            nvimView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            nvimView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            nvimView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        customTitleLabel = titleLabel
        window.makeFirstResponder(nvimView)
    }

    func updateTitle(_ title: String) {
        customTitleLabel?.stringValue = title
        window?.title = title
    }

    func windowDidResize(_ notification: Notification) {
        saveWindowFrame()
        let contentSize = nvimView.bounds.size
        (document as? WindowDocument)?.windowDidResize(to: contentSize)
    }

    func windowDidMove(_ notification: Notification) {
        saveWindowFrame()
    }

    // nvim_ui_set_focus tells nvim the GUI gained or lost OS focus, so nvim
    // fires its FocusGained/FocusLost autocmds internally. checktime then
    // asks nvim to compare open buffers against disk — if a file was modified
    // externally (e.g. edited in another app) and the user has `set autoread`,
    // nvim reloads it automatically.
    //
    // When nvim exits (e.g. :qa), the window closes and windowDidResignKey
    // still fires. The RPC write hits a closed pipe, but SIGPIPE is ignored
    // and MsgpackRpc.request catches the write error, so this is safe.
    func windowDidBecomeKey(_ notification: Notification) {
        window?.makeFirstResponder(nvimView)
        if let channel = (document as? WindowDocument)?.channel {
            Task {
                _ = await channel.request("nvim_ui_set_focus", params: [.bool(true)])
                try? await channel.command("checktime")
            }
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        if let channel = (document as? WindowDocument)?.channel {
            Task { _ = await channel.request("nvim_ui_set_focus", params: [.bool(false)]) }
        }
    }

    private func saveWindowFrame() {
        guard let frame = window?.frame else { return }
        UserDefaults.standard.set(NSStringFromRect(frame), forKey: "VeilWindowFrame")
    }
}
