import AppKit
import CoreVideo
import MessagePack

class WindowDocument: NSDocument, NvimViewDelegate {
    var profile = Profile.default
    var nvimArgs: [String] = []
    var nvimEnv: [String: String]?
    var preferredRenderer: NvimView.Renderer = .metal
    /// When true, this document is connected to a remote nvim over TCP.
    /// Closing a remote document disconnects without sending `:qa`.
    var isRemote = false
    /// Address for remote connections (e.g. "192.168.1.100:6666").
    var remoteAddress: String?

    var channel: NvimChannel!
    private let grid = Grid()
    private var eventLoopTask: Task<Void, Never>?
    // Window title strategy:
    //
    // We enable `set title` so nvim sends `set_title` events with its titlestring
    // (e.g. "init.lua (~/.config/nvim/lua/plugins) - Nvim"). However, `set title`
    // fires immediately when enabled, producing an ugly title from whatever buffer
    // is current at startup (e.g. Startify's "filetype-match-scratch...").
    //
    // To avoid this, we register BufEnter/TabEnter autocmds BEFORE enabling
    // `set title`. Since autocmds don't fire retroactively for the initial buffer,
    // the first BufEnter only arrives when the user actually switches buffers.
    // We use `titleReady` as a one-time gate: false at startup to suppress the
    // initial ugly set_title, flipped to true on first BufEnter, then stays true
    // forever — all subsequent set_title events are displayed normally.
    //
    // Exception: when nvimArgs is non-empty (files passed via CLI or Finder Open
    // With), nvim opens the file directly without Startify, so the initial
    // set_title is already the correct filename. In this case titleReady starts
    // as true to avoid suppressing it.
    private var titleReady = false

    /// Frame coalescing: set true on flush, cleared after render.
    /// CVDisplayLink fires at screen refresh rate and only renders when dirty,
    /// preventing main-thread vsync stalls when nvim flushes faster than 60fps.
    private var needsRender = false
    private var displayLink: CVDisplayLink?
    private var displayLinkContext: Unmanaged<DisplayLinkContext>?

    private var windowController: WindowController? {
        windowControllers.first as? WindowController
    }

    private var nvimView: NvimView? {
        windowController?.nvimView
    }

    override init() {
        super.init()
        self.channel = NvimChannel()
    }

    override var displayName: String! {
        get { "Veil" }
        set {}
    }

    override func makeWindowControllers() {
        let controller = WindowController()
        controller.nvimView.preferredRenderer = preferredRenderer
        controller.nvimView.setupLayers()
        controller.nvimView.delegate = self
        controller.nvimView.channel = channel
        addWindowController(controller)
        if isRemote, let remoteAddress {
            Task { await startRemoteNvim(address: remoteAddress) }
        } else {
            Task { await startNvim() }
        }
    }

    nonisolated override class var autosavesInPlace: Bool { false }
    override func data(ofType typeName: String) throws -> Data { Data() }
    nonisolated override func read(from data: Data, ofType typeName: String) throws {}

    private func startRemoteNvim(address: String) async {
        titleReady = true
        do {
            let (host, port) = try Self.parseAddress(address)
            try await channel.connectRemote(host: host, port: port)
            guard let nvimView else { return }
            let gridSize = nvimView.gridSizeForViewSize(nvimView.bounds.size)
            try await channel.uiAttach(
                width: gridSize.cols, height: gridSize.rows,
                nativeTabs: VeilConfig.current.native_tabs)
            startEventLoop()
            await setupNvimIntegration()
            nvimView.remoteAddress = address
            windowController?.updateTitle("Veil [remote: \(address)]")
            try? await channel.command("set title")
        } catch {
            NSAlert(error: error).runModal()
            close()
        }
    }

    /// Parse "host:port" (or "tcp://host:port") into components.
    /// Uses URL parsing which handles IPv4, IPv6 bracket notation, and scheme URLs.
    private static func parseAddress(_ input: String) throws -> (host: String, port: UInt16) {
        let url = URL(string: input) ?? URL(string: "tcp://\(input)")
        guard let host = url?.host, !host.isEmpty, let port = url?.port,
            let port = UInt16(exactly: port)
        else {
            throw NvimChannelError.rpcError("Invalid address format. Expected host:port")
        }
        return (host, port)
    }

    private func startNvim() async {
        if !nvimArgs.isEmpty { titleReady = true }
        do {
            let cwd =
                nvimEnv?["PWD"]
                ?? ProcessInfo.processInfo.environment["PWD"]
                ?? NSHomeDirectory()
            try await channel.start(
                nvimPath: VeilConfig.current.nvim_path, cwd: cwd, appName: profile.name,
                extraArgs: nvimArgs, env: nvimEnv)
            guard let nvimView else { return }
            let gridSize = nvimView.gridSizeForViewSize(nvimView.bounds.size)
            try await channel.uiAttach(
                width: gridSize.cols, height: gridSize.rows,
                nativeTabs: VeilConfig.current.native_tabs)
            startEventLoop()

            // Register autocmds AFTER uiAttach. The initial BufEnter fires
            // during nvim startup (before this point), so it's intentionally
            // missed. This keeps titleReady false, suppressing the ugly initial
            // set_title from Startify or similar plugins.
            await setupNvimIntegration()
            nvimView.nvimPath = await channel.nvimPath

            // Enable nvim title. set_title events will be ignored until first BufEnter.
            try? await channel.command("set title")
        } catch {
            NSAlert(error: error).runModal()
            close()
        }
    }

    /// Shared post-uiAttach setup: wire up tab selection, register autocmds
    /// for BufEnter/TabEnter notifications, debug commands, and query nvim version.
    private func setupNvimIntegration() async {
        let channel = self.channel!
        windowController?.tablineView.onSelectTab = { [weak self] handle in
            guard self != nil else { return }
            Task {
                _ = await channel.request(
                    "nvim_set_current_tabpage",
                    params: [.int(Int64(handle))]
                )
            }
        }

        let (_, chanInfo) = await channel.request(
            "nvim_get_chan_info", params: [.int(0)])
        if let channelId = chanInfo.dictionaryValue?[.string("id")]?.intValue, channelId > 0 {
            try? await channel.command(
                "augroup VeilApp | autocmd! | "
                    + "autocmd BufEnter * call rpcnotify(\(channelId), 'VeilAppBufChanged') | "
                    + "autocmd TabEnter * call rpcnotify(\(channelId), 'VeilAppBufChanged') | "
                    + "augroup END"
            )
            try? await channel.command(
                "command! VeilAppDebugToggle call rpcnotify(\(channelId), 'VeilAppDebugToggle')"
            )
            try? await channel.command(
                "command! VeilAppDebugCopy call rpcnotify(\(channelId), 'VeilAppDebugCopy')"
            )

            if await channel.isRemote {
                await injectClipboardProvider(channelId: channelId)
            }
        }

        let (_, versionResult) = await channel.request(
            "nvim_exec2", params: [.string("version"), .map([.string("output"): .bool(true)])])
        if let output = versionResult.dictionaryValue?[.string("output")]?.stringValue,
            let firstLine = output.split(separator: "\n").first
        {
            nvimView?.nvimVersion = String(firstLine)
        }
    }

    /// In remote mode, inject a g:clipboard provider that routes clipboard
    /// operations through RPC back to the local Mac pasteboard.
    private func injectClipboardProvider(channelId: Int) async {
        // If g:clipboard exists but g:VeilAppClipboardInjected is absent,
        // the user configured their own provider and we should not override it.
        // If we injected it previously (e.g. prior connection), re-inject with
        // the new channel ID so rpcrequest targets the current connection.
        let (_, existsResult) = await channel.request(
            "nvim_eval",
            params: [.string("exists('g:clipboard') && !exists('g:VeilAppClipboardInjected')")]
        )
        if existsResult.intValue == 1 { return }

        let lua = """
            vim.g.VeilAppClipboardInjected = true
            vim.g.clipboard = {
              name = 'VeilClipboard',
              copy = {
                ['+'] = function(lines, regtype)
                  vim.rpcrequest(\(channelId), 'VeilAppClipboardSet', lines, regtype)
                end,
                ['*'] = function(lines, regtype)
                  vim.rpcrequest(\(channelId), 'VeilAppClipboardSet', lines, regtype)
                end,
              },
              paste = {
                ['+'] = function()
                  return vim.rpcrequest(\(channelId), 'VeilAppClipboardGet')
                end,
                ['*'] = function()
                  return vim.rpcrequest(\(channelId), 'VeilAppClipboardGet')
                end,
              },
            }
            -- Force reload clipboard provider so it picks up the new g:clipboard
            package.loaded['vim.provider.clipboard'] = nil
            vim.g.loaded_clipboard_provider = nil
            vim.cmd('runtime autoload/provider/clipboard.vim')
            """
        let (clipErr, _) = await channel.request(
            "nvim_exec_lua", params: [.string(lua), .array([])])
        if clipErr != .nil {
            NSLog("Veil: clipboard provider injection failed: %@", "\(clipErr)")
        }
    }

    private func startEventLoop() {
        startDisplayLink()
        eventLoopTask = Task { @MainActor in
            let events = channel.events
            for await batch in events {
                for event in batch {
                    grid.apply(event)
                    switch event {
                    case .flush:
                        // Don't render immediately; mark dirty and let the
                        // CVDisplayLink callback render at screen refresh rate.
                        needsRender = true
                    case .setTitle(let title):
                        if titleReady {
                            // Replace nvim's hardcoded "- Nvim" suffix with
                            // "- Veil" or "- Veil [Remote]" depending on mode.
                            let suffix = isRemote ? " - Veil [Remote]" : " - Veil"
                            let displayTitle =
                                title.hasSuffix(" - Nvim")
                                ? String(title.dropLast(6)) + suffix
                                : title
                            windowController?.updateTitle(displayTitle)
                        }
                    case .veilBufChanged:
                        titleReady = true
                    case .veilDebugToggle:
                        nvimView?.debugOverlayEnabled.toggle()
                        needsRender = true
                    case .veilDebugCopy:
                        if let text = nvimView?.debugInfoText() {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(text, forType: .string)
                        }
                    case .tablineUpdate(let current, let tabs):
                        windowController?.tablineView.update(current: current, tabInfos: tabs)
                    case .defaultColorsSet(let fg, let bg, _, _, _):
                        nvimView?.setDefaultColors(fg: fg, bg: bg)
                        windowController?.updateTitleBarColors(fg: fg, bg: bg)
                    case .modeInfoSet(_, let modes):
                        nvimView?.updateModeInfo(modes)
                    case .modeChange(_, let index):
                        nvimView?.updateCursorMode(index)
                    case .bell:
                        NSSound.beep()
                    case .optionSet(let name, let value):
                        if name == "guifont", let fontStr = value.stringValue, !fontStr.isEmpty {
                            nvimView?.parseAndSetGuifont(fontStr)
                            if let nvimView {
                                let newGridSize = nvimView.gridSizeForViewSize(nvimView.bounds.size)
                                Task {
                                    await channel.uiTryResize(
                                        width: newGridSize.cols, height: newGridSize.rows)
                                }
                            }
                        }
                    default:
                        break
                    }
                }
            }
            close()
        }
    }

    // MARK: - CVDisplayLink frame pacing

    /// Start a CVDisplayLink that fires at screen refresh rate.
    /// The callback dispatches to main thread where we check needsRender
    /// and render at most once per vsync, coalescing multiple flushes.
    private func startDisplayLink() {
        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard let link else { return }

        let context = DisplayLinkContext(document: self)
        let retained = Unmanaged.passRetained(context)
        displayLinkContext = retained

        CVDisplayLinkSetOutputCallback(link, displayLinkCallback, retained.toOpaque())
        CVDisplayLinkStart(link)
        displayLink = link
    }

    private func stopDisplayLink() {
        if let link = displayLink {
            CVDisplayLinkStop(link)
            displayLink = nil
        }
        // Balance the passRetained from startDisplayLink
        displayLinkContext?.release()
        displayLinkContext = nil
    }

    /// Called from CVDisplayLink callback on main thread.
    /// Renders at most once per vsync, coalescing all flushes since last frame.
    fileprivate func displayLinkFired() {
        guard needsRender else { return }
        needsRender = false
        nvimView?.render(grid: grid)
        grid.clearDirty()
    }

    override func canClose(
        withDelegate delegate: Any, shouldClose shouldCloseSelector: Selector?,
        contextInfo: UnsafeMutableRawPointer?
    ) {
        if isRemote {
            // Remote connection: just disconnect. The remote nvim stays alive.
            replyToCanClose(
                true, delegate: delegate, selector: shouldCloseSelector, contextInfo: contextInfo)
        } else {
            Task { @MainActor in
                // Send :confirm qa to let nvim prompt for unsaved buffers
                try? await channel.command("confirm qa")
                // Don't allow NSDocument to close; the window closes when nvim
                // exits (event stream ends -> close() is called from event loop)
            }
            replyToCanClose(
                false, delegate: delegate, selector: shouldCloseSelector, contextInfo: contextInfo)
        }
    }

    /// NSDocument canClose callback pattern: the framework doesn't accept a
    /// direct return value. Instead, you must invoke the delegate's selector
    /// with a Bool indicating whether the document should close.
    private func replyToCanClose(
        _ shouldClose: Bool, delegate: Any, selector: Selector?,
        contextInfo: UnsafeMutableRawPointer?
    ) {
        guard let selector else { return }
        let obj = delegate as AnyObject
        typealias ShouldCloseFunc =
            @convention(c) (AnyObject, Selector, AnyObject, Bool, UnsafeMutableRawPointer?) -> Void
        let imp = obj.method(for: selector)
        let fn = unsafeBitCast(imp, to: ShouldCloseFunc.self)
        fn(obj, selector, self, shouldClose, contextInfo)
    }

    override func close() {
        stopDisplayLink()
        eventLoopTask?.cancel()
        Task { await channel.stop() }
        super.close()
    }

    func nvimViewNeedsDisplay(_ view: NvimView) {
        view.render(grid: grid)
    }

    func redraw() {
        // Prevent white flash on initial window creation: only allow redraw
        // after the event loop has rendered at least once. windowDidBecomeKey
        // fires before neovim sends grid_resize, and the empty grid defaults
        // to a white background which cause white flash.
        guard grid.size != .zero else { return }
        nvimView?.render(grid: grid)
    }

    func windowDidResize(to size: NSSize) {
        guard let nvimView else { return }
        let gridSize = nvimView.gridSizeForViewSize(size)
        guard gridSize.rows > 0, gridSize.cols > 0 else { return }
        Task { await channel.uiTryResize(width: gridSize.cols, height: gridSize.rows) }
    }
}

// MARK: - CVDisplayLink callback plumbing

/// Prevent retain cycle: CVDisplayLink C callback captures a raw pointer
/// to this context, which holds a weak reference back to the document.
private final class DisplayLinkContext {
    weak var document: WindowDocument?
    init(document: WindowDocument) { self.document = document }
}

/// CVDisplayLink C function callback. Runs on a high-priority display thread,
/// so we dispatch to main for the actual render (Metal/AppKit require it).
private func displayLinkCallback(
    _ displayLink: CVDisplayLink,
    _ inNow: UnsafePointer<CVTimeStamp>,
    _ inOutputTime: UnsafePointer<CVTimeStamp>,
    _ flagsIn: CVOptionFlags,
    _ flagsOut: UnsafeMutablePointer<CVOptionFlags>,
    _ context: UnsafeMutableRawPointer?
) -> CVReturn {
    guard let context else { return kCVReturnSuccess }
    let ctx = Unmanaged<DisplayLinkContext>.fromOpaque(context).takeUnretainedValue()
    DispatchQueue.main.async {
        ctx.document?.displayLinkFired()
    }
    return kCVReturnSuccess
}
