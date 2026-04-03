import Cocoa

private let veilEventClass = AEEventClass(bitPattern: fourCharCode("Veil"))
private let veilOpenEventID = AEEventID(bitPattern: fourCharCode("Open"))
private let veilJSONParamKey = AEKeyword(bitPattern: fourCharCode("json"))

private func fourCharCode(_ s: String) -> Int32 {
    let chars = Array(s.utf8)
    return Int32(chars[0]) << 24 | Int32(chars[1]) << 16 | Int32(chars[2]) << 8 | Int32(chars[3])
}

@main
class AppDelegate: NSObject, NSApplicationDelegate {
    // Parse CLI args eagerly at init time, before any delegate methods run.
    // application(_:openFiles:) can fire before applicationDidFinishLaunching
    // when macOS detects file arguments matching registered document types.
    private(set) lazy var parsedArgs: CliArgParser.Result = CliArgParser.parse(
        ProcessInfo.processInfo.arguments)
    /// Arguments to forward to nvim, parsed from the CLI invocation.
    /// Veil-specific flags (e.g. --veil-renderer) are already stripped by
    /// CliArgParser; what remains are nvim flags (-d, -p) and file paths.
    private var initialNvimArgs: [String] {
        get { parsedArgs.nvimArgs }
        set { parsedArgs.nvimArgs = newValue }
    }
    var preferredRenderer: NvimView.Renderer { parsedArgs.renderer }

    func applicationDidFinishLaunching(_ aNotification: Notification) {

        // Writing to a closed pipe sends SIGPIPE, which terminates the process
        // by default. This happens when nvim exits but an RPC call is still
        // in flight (e.g. windowDidResignKey sends nvim_ui_set_focus after
        // :qa closes the nvim process). Ignoring the signal lets the write
        // fail with EPIPE instead, which MsgpackRpc.request catches gracefully.
        signal(SIGPIPE, SIG_IGN)

        // Enforce single instance. A second instance can be spawned by running
        // the binary directly from Terminal, `open -n`, or Spotlight. When that
        // happens, forward file arguments and environment to the existing
        // instance via a custom Apple Event (point-to-point, system-guaranteed
        // delivery). We avoid NSWorkspace for file forwarding because it
        // validates file existence and shows a Finder alert for non-existent
        // paths, but nvim handles those gracefully as [New File] buffers.
        let bundleId = Bundle.main.bundleIdentifier!
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            .filter { $0 != .current }
        if let existing = others.first {
            forwardToExistingInstance(existing)
        }

        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleVeilOpenEvent(_:withReply:)),
            forEventClass: veilEventClass, andEventID: veilOpenEventID
        )

        Task.detached { NvimProcess.warmUpEnvironment() }
        addProfilePickerMenuItem()
        addDebugOverlayMenuItem()
        NSApp.activate(ignoringOtherApps: true)

        // Defer default window creation — if openFiles: is called (Finder launch),
        // a window will already exist, so we skip the default one.
        DispatchQueue.main.async {
            if NSDocumentController.shared.documents.isEmpty {
                self.createWindow(profile: self.profileFromEnvironment())
            }
        }
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        if !initialNvimArgs.isEmpty {
            // Cold start: macOS detected file arguments matching registered
            // document types. The same files are already in initialNvimArgs
            // (parsed by CliArgParser), which also preserves nvim flags like
            // -d that macOS strips. Let the deferred createWindow() handle
            // everything so flags aren't lost.
        } else {
            // App already running (Finder Open With, drag to Dock icon).
            let doc = WindowDocument()
            doc.profile = profileFromEnvironment()
            doc.preferredRenderer = preferredRenderer
            doc.nvimArgs = filenames
            NSDocumentController.shared.addDocument(doc)
            doc.makeWindowControllers()
            doc.showWindows()
        }
        NSApp.reply(toOpenOrPrint: .success)
    }

    func applicationWillTerminate(_ aNotification: Notification) {}

    // Quit strategy: delegate quit confirmation to nvim via `:confirm qa`.
    // We return .terminateLater to keep the termination pending, then
    // sequentially ask each document to quit:
    //
    // - If no buffers are modified, `confirm qa` causes nvim to exit
    //   immediately. The RPC call throws (connection lost) and we move on.
    // - If buffers are modified, nvim prompts the user inside the terminal.
    //   Save/discard → nvim exits → throws, same as above.
    //   Cancel → nvim stays running → command returns normally →
    //   we reply(false) to abort termination.
    // - After all documents have exited, we reply(true) to finish termination.
    //
    // WindowDocument.close() deliberately contains no quit logic — it only
    // handles cleanup (cancel event loop, stop channel). The quit decision
    // is fully driven by the sequential loop here.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let documents = NSDocumentController.shared.documents.compactMap { $0 as? WindowDocument }
        if documents.isEmpty { return .terminateNow }

        Task { @MainActor in
            for doc in documents {
                do {
                    try await doc.channel.command("confirm qa")
                    // Command returned normally — user cancelled the quit prompt
                    NSApp.reply(toApplicationShouldTerminate: false)
                    return
                } catch {
                    // Command threw — nvim exited, continue to next document
                }
            }
            // All documents closed successfully
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    // MARK: - Window Creation

    /// Cmd+N: create a new window with the last-used profile directly (no picker).
    @IBAction func newDocument(_ sender: Any?) {
        createWindow(profile: Profile.default)
    }

    /// Cmd+Shift+N: show profile picker then create window.
    @IBAction func newDocumentWithProfilePicker(_ sender: Any?) {
        ProfilePicker.pick(in: NSApp.keyWindow) { profile in
            self.createWindow(profile: profile)
        }
    }

    /// Read NVIM_APPNAME from the process environment to select a nvim profile.
    /// This is how CLI invocations (e.g. `NVIM_APPNAME=nvim-nvchad gvim`) choose
    /// which config directory nvim uses on initial launch.
    private func profileFromEnvironment() -> Profile {
        if let appName = ProcessInfo.processInfo.environment["NVIM_APPNAME"] {
            return Profile(name: appName, displayName: appName)
        }
        return Profile.default
    }

    /// Creates and shows a new WindowDocument with the given profile.
    func createWindow(profile: Profile) {
        let doc = WindowDocument()
        doc.profile = profile
        doc.preferredRenderer = preferredRenderer
        if !initialNvimArgs.isEmpty {
            doc.nvimArgs = initialNvimArgs
            initialNvimArgs = []
        }
        NSDocumentController.shared.addDocument(doc)
        doc.makeWindowControllers()
        doc.showWindows()
    }

    // MARK: - Single Instance Forwarding

    /// Forward file arguments and environment to an existing Veil instance
    /// via a custom Apple Event, then terminate. The JSON payload carries
    /// file paths, the full shell environment, and NVIM_APPNAME so the
    /// existing instance can open a new window with the correct nvim profile.
    private func forwardToExistingInstance(_ existing: NSRunningApplication) -> Never {
        // Forward NVIM_APPNAME so the existing instance opens the window
        // with the correct nvim profile (e.g. NVIM_APPNAME=nvim-nvchad gvim).
        let nvimAppName = ProcessInfo.processInfo.environment["NVIM_APPNAME"]
        if !initialNvimArgs.isEmpty || nvimAppName != nil {
            var payload: [String: Any] = [
                "nvimArgs": initialNvimArgs,
                "env": ProcessInfo.processInfo.environment,
            ]
            if let nvimAppName { payload["nvimAppName"] = nvimAppName }
            if let data = try? JSONSerialization.data(withJSONObject: payload),
                let json = String(data: data, encoding: .utf8)
            {
                let target = NSAppleEventDescriptor(processIdentifier: existing.processIdentifier)
                let event = NSAppleEventDescriptor(
                    eventClass: veilEventClass,
                    eventID: veilOpenEventID,
                    targetDescriptor: target,
                    returnID: AEReturnID(kAutoGenerateReturnID),
                    transactionID: AETransactionID(kAnyTransactionID))
                event.setParam(
                    NSAppleEventDescriptor(string: json),
                    forKeyword: veilJSONParamKey)
                _ = try? event.sendEvent(
                    options: .noReply,
                    timeout: TimeInterval(kAEDefaultTimeout))
            }
        }
        existing.activate()
        // Terminate immediately — no resources to clean up, event
        // already delivered, just get out of the way.
        exit(0)
    }

    @objc private func handleVeilOpenEvent(
        _ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor
    ) {
        guard let json = event.paramDescriptor(forKeyword: veilJSONParamKey)?.stringValue,
            let data = json.data(using: .utf8),
            let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        let nvimArgs = payload["nvimArgs"] as? [String] ?? []
        let env = payload["env"] as? [String: String]
        if let env {
            NvimProcess.updateCachedEnv(from: env)
        }
        // Use forwarded NVIM_APPNAME to select the correct nvim profile,
        // falling back to default if not specified.
        let nvimAppName = payload["nvimAppName"] as? String
        let profile = nvimAppName.map { Profile(name: $0, displayName: $0) } ?? Profile.default
        let doc = WindowDocument()
        doc.profile = profile
        doc.preferredRenderer = preferredRenderer
        doc.nvimArgs = nvimArgs
        doc.nvimEnv = env
        NSDocumentController.shared.addDocument(doc)
        doc.makeWindowControllers()
        doc.showWindows()
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Menu Setup

    private func addDebugOverlayMenuItem() {
        guard let mainMenu = NSApp.mainMenu,
            let viewMenu = mainMenu.items.first(where: { $0.title == "View" })?.submenu
        else { return }
        viewMenu.addItem(NSMenuItem.separator())
        viewMenu.addItem(
            NSMenuItem(
                title: "Toggle Debug Overlay",
                action: #selector(NvimView.toggleDebugOverlay(_:)),
                keyEquivalent: ""))
    }

    private func addProfilePickerMenuItem() {
        guard let mainMenu = NSApp.mainMenu,
            let fileMenu = mainMenu.items.first(where: { $0.title == "File" })?.submenu
        else { return }

        // Find "New" item (Cmd+N) and insert our item after it.
        let newItemIndex =
            fileMenu.items.firstIndex(where: {
                $0.keyEquivalent == "n" && $0.keyEquivalentModifierMask == .command
            }) ?? 0

        let pickerItem = NSMenuItem(
            title: "New Window with Profile…",
            action: #selector(newDocumentWithProfilePicker(_:)),
            keyEquivalent: "N"  // Shift+Cmd+N (uppercase N means Shift+Cmd+N in Cocoa)
        )
        pickerItem.keyEquivalentModifierMask = [.command, .shift]
        pickerItem.target = self
        fileMenu.insertItem(pickerItem, at: newItemIndex + 1)
    }
}
