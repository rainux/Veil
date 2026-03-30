import AppKit
import MessagePack

class WindowDocument: NSDocument {
    var profile = Profile.default
    var nvimArgs: [String] = []

    var channel: NvimChannel!
    private let grid = Grid()
    private var eventLoopTask: Task<Void, Never>?
    // Window title strategy (similar to VimR):
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
    private var titleReady = false

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
        set { }
    }

    override func makeWindowControllers() {
        let controller = WindowController()
        controller.nvimView.channel = channel
        addWindowController(controller)
        Task { await startNvim() }
    }

    nonisolated override class var autosavesInPlace: Bool { false }
    override func data(ofType typeName: String) throws -> Data { Data() }
    nonisolated override func read(from data: Data, ofType typeName: String) throws {}

    private func startNvim() async {
        do {
            try await channel.start(nvimPath: "", cwd: NSHomeDirectory(), appName: profile.name, extraArgs: nvimArgs)
            guard let nvimView else { return }
            let gridSize = nvimView.gridSizeForViewSize(nvimView.bounds.size)
            try await channel.uiAttach(width: gridSize.cols, height: gridSize.rows)
            startEventLoop()

            // Register autocmds for title updates on buffer/tab changes
            let (_, apiInfo) = await channel.request("nvim_get_api_info", params: [])
            if let channelId = apiInfo.arrayValue?.first?.intValue {
                try? await channel.command(
                    "augroup VeilApp | autocmd! | " +
                    "autocmd BufEnter * call rpcnotify(\(channelId), 'VeilAppBufChanged') | " +
                    "autocmd TabEnter * call rpcnotify(\(channelId), 'VeilAppBufChanged') | " +
                    "augroup END"
                )
            }

            // Enable nvim title — set_title events will be ignored until first BufEnter
            try? await channel.command("set title")
        } catch {
            NSAlert(error: error).runModal()
            close()
        }
    }

    private func startEventLoop() {
        eventLoopTask = Task { @MainActor in
            let events = channel.events
            for await event in events {
                grid.apply(event)
                switch event {
                case .flush:
                    nvimView?.render(grid: grid)
                    grid.clearDirty()
                case .setTitle(let title):
                    if titleReady {
                        windowController?.updateTitle(title)
                    }
                case .veilBufChanged:
                    titleReady = true
                case .defaultColorsSet(let fg, let bg, _, _, _):
                    nvimView?.setDefaultColors(fg: fg, bg: bg)
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
                                await channel.uiTryResize(width: newGridSize.cols, height: newGridSize.rows)
                            }
                        }
                    }
                default:
                    break
                }
            }
            close()
        }
    }

    override func canClose(withDelegate delegate: Any, shouldClose shouldCloseSelector: Selector?, contextInfo: UnsafeMutableRawPointer?) {
        Task { @MainActor in
            // Send :confirm qa — nvim will prompt inside the terminal if unsaved buffers exist
            try? await channel.command("confirm qa")
            // Don't allow NSDocument to close — the window closes when nvim exits
            // (event stream ends → close() is called from the event loop)
        }
        // Tell NSDocument NOT to close right now
        if let selector = shouldCloseSelector {
            let obj = delegate as AnyObject
            typealias ShouldCloseFunc = @convention(c) (AnyObject, Selector, AnyObject, Bool, UnsafeMutableRawPointer?) -> Void
            let imp = obj.method(for: selector)
            let fn = unsafeBitCast(imp, to: ShouldCloseFunc.self)
            fn(obj, selector, self, false, contextInfo)
        }
    }

    override func close() {
        eventLoopTask?.cancel()
        Task { await channel.stop() }
        super.close()
    }

    func windowDidResize(to size: NSSize) {
        guard let nvimView else { return }
        let gridSize = nvimView.gridSizeForViewSize(size)
        guard gridSize.rows > 0, gridSize.cols > 0 else { return }
        Task { await channel.uiTryResize(width: gridSize.cols, height: gridSize.rows) }
    }
}
