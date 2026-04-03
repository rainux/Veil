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
        // Title bar colors are derived from neovim's default fg/bg, cached in
        // UserDefaults so the window opens with the correct colors immediately,
        // avoiding a visible flash when neovim's colorscheme loads later.
        // First launch has no cache and falls back to system appearance colors.
        // The title bar bg is darkened relative to the content bg to give the
        // chrome a grounded, recessive look that visually separates it from
        // the editing area without clashing with the colorscheme.
        let defaults = UserDefaults.standard
        if let cachedBg = defaults.object(forKey: "VeilDefaultBg") as? Int {
            window.backgroundColor = NSColor(rgb: Self.darkenColor(cachedBg, factor: 0.75))
        } else {
            window.backgroundColor = .windowBackgroundColor
        }

        self.init(window: window)
        window.delegate = self

        let titleLabel = NSTextField(labelWithString: "Veil")
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .titleBarFont(ofSize: 0)
        if let cachedFg = defaults.object(forKey: "VeilDefaultFg") as? Int {
            titleLabel.textColor = NSColor(rgb: cachedFg)
        } else {
            titleLabel.textColor = .windowFrameTextColor
        }
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
            titleLabel.centerYAnchor.constraint(
                equalTo: container.topAnchor, constant: titleBarHeight / 2),
            titleLabel.widthAnchor.constraint(
                lessThanOrEqualTo: container.widthAnchor, constant: -160),

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

    func updateTitleBarColors(fg: Int, bg: Int) {
        let titleBg = Self.darkenColor(bg, factor: 0.75)
        window?.backgroundColor = NSColor(rgb: titleBg)
        customTitleLabel?.textColor = NSColor(rgb: fg)
        UserDefaults.standard.set(fg, forKey: "VeilDefaultFg")
        UserDefaults.standard.set(bg, forKey: "VeilDefaultBg")
    }

    private static func darkenColor(_ rgb: Int, factor: CGFloat) -> Int {
        let r = Int(CGFloat((rgb >> 16) & 0xFF) * factor)
        let g = Int(CGFloat((rgb >> 8) & 0xFF) * factor)
        let b = Int(CGFloat(rgb & 0xFF) * factor)
        return (r << 16) | (g << 8) | b
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
        // Force a full redraw when returning from another Space or app.
        // Metal drawable content may be stale after being offscreen.
        (document as? WindowDocument)?.redraw()
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
