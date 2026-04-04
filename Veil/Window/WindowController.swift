import AppKit
import MessagePack

class WindowController: NSWindowController, NSWindowDelegate {
    private static let titleBarBrightnessOffset: CGFloat = -0.08
    private static let tabBarBrightnessOffset: CGFloat = 0.05

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
        if let frameString = UserDefaults.standard.string(forKey: "VeilWindowFrame") {
            window.setFrame(NSRectFromString(frameString), display: false)
        } else if let screen = NSScreen.main {
            window.setFrame(screen.visibleFrame, display: false)
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
        let cachedBg = defaults.object(forKey: "VeilDefaultBg") as? Int ?? 0x1E1E2E
        window.backgroundColor = NSColor(
            rgb: Self.tintedGray(from: cachedBg, offset: Self.titleBarBrightnessOffset))

        self.init(window: window)
        window.delegate = self

        let titleLabel = NSTextField(labelWithString: "Veil")
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .titleBarFont(ofSize: 0)
        let cachedFg = defaults.object(forKey: "VeilDefaultFg") as? Int ?? 0xCCCCCC
        titleLabel.textColor = NSColor(rgb: cachedFg)
        titleLabel.lineBreakMode = .byTruncatingTail

        let container = NSView()
        container.wantsLayer = true
        container.translatesAutoresizingMaskIntoConstraints = false
        nvimView.translatesAutoresizingMaskIntoConstraints = false
        tablineView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(tablineView)
        container.addSubview(nvimView)
        container.addSubview(titleLabel)
        window.contentView = container

        let titleBarHeight: CGFloat = 28
        NSLayoutConstraint.activate([
            titleLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            titleLabel.centerYAnchor.constraint(
                equalTo: container.topAnchor, constant: titleBarHeight / 2),
            titleLabel.widthAnchor.constraint(
                lessThanOrEqualTo: container.widthAnchor, constant: -160),

            tablineView.topAnchor.constraint(
                equalTo: container.topAnchor, constant: titleBarHeight),
            tablineView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tablineView.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            nvimView.topAnchor.constraint(equalTo: tablineView.bottomAnchor),
            nvimView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            nvimView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            nvimView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        customTitleLabel = titleLabel
        tablineView.bgColor = NSColor(
            rgb: Self.tintedGray(from: cachedBg, offset: Self.tabBarBrightnessOffset))
        tablineView.fgColor = NSColor(rgb: cachedFg)
        window.makeFirstResponder(nvimView)
    }

    func updateTitle(_ title: String) {
        customTitleLabel?.stringValue = title
        window?.title = title
    }

    func updateTitleBarColors(fg: Int, bg: Int) {
        let titleBg = Self.tintedGray(from: bg, offset: Self.titleBarBrightnessOffset)
        let tabBg = Self.tintedGray(from: bg, offset: Self.tabBarBrightnessOffset)
        window?.backgroundColor = NSColor(rgb: titleBg)
        customTitleLabel?.textColor = NSColor(rgb: fg)
        tablineView.bgColor = NSColor(rgb: tabBg)
        tablineView.fgColor = NSColor(rgb: fg)
        tablineView.needsDisplay = true
        UserDefaults.standard.set(fg, forKey: "VeilDefaultFg")
        UserDefaults.standard.set(bg, forKey: "VeilDefaultBg")
    }

    /// Extract the hue from an RGB color and return a new color with the same
    /// tint but brightness nudged toward the middle. Dark backgrounds get
    /// slightly brighter, light backgrounds get slightly darker. This keeps
    /// the tab bar visually distinct from both the title bar and content area
    /// regardless of colorscheme.
    private static func tintedGray(from rgb: Int, offset: CGFloat = 0.08) -> Int {
        let r = CGFloat((rgb >> 16) & 0xFF) / 255
        let g = CGFloat((rgb >> 8) & 0xFF) / 255
        let b = CGFloat(rgb & 0xFF) / 255
        let nsColor = NSColor(red: r, green: g, blue: b, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, bri: CGFloat = 0
        if let c = nsColor.usingColorSpace(.deviceRGB) {
            h = c.hueComponent
            s = c.saturationComponent
            bri = c.brightnessComponent
        }
        // Nudge brightness toward middle: dark gets brighter, light gets darker
        let newBri = bri < 0.5 ? bri + offset : bri - offset
        let tinted = NSColor(
            hue: h, saturation: s, brightness: max(0, min(1, newBri)), alpha: 1)
        let rr = Int(tinted.redComponent * 255)
        let gg = Int(tinted.greenComponent * 255)
        let bb = Int(tinted.blueComponent * 255)
        return (rr << 16) | (gg << 8) | bb
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
