import Cocoa

extension NSNotification.Name {
    static let veilOpenFiles = NSNotification.Name("com.veil.openFiles")
}

@main
class AppDelegate: NSObject, NSApplicationDelegate {
    // Parse CLI args eagerly at init time, before any delegate methods run.
    // application(_:openFiles:) can fire before applicationDidFinishLaunching
    // when macOS detects file arguments matching registered document types.
    private(set) lazy var parsedArgs: CliArgParser.Result = CliArgParser.parse(
        ProcessInfo.processInfo.arguments)
    private var initialCliArgs: [String] {
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
        // happens, forward any file arguments to the existing instance via
        // DistributedNotificationCenter (not NSWorkspace, which validates file
        // existence and shows a Finder alert for non-existent files — but nvim
        // handles those gracefully as [New File] buffers).
        //
        // File paths are JSON-encoded in the notification's `object` parameter
        // because macOS 10.15+ strips `userInfo` from cross-process distributed
        // notifications for security reasons.
        let bundleId = Bundle.main.bundleIdentifier!
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            .filter { $0 != .current }
        if let existing = others.first {
            // Resolve relative paths before forwarding — the existing instance
            // has a different cwd, so "Makefile" would resolve to the wrong file.
            let absolutePaths = initialCliArgs.map { URL(fileURLWithPath: $0).path }
            // Forward NVIM_APPNAME so the existing instance opens the window
            // with the correct nvim profile (e.g. NVIM_APPNAME=nvim-nvchad gvim).
            let nvimAppName = ProcessInfo.processInfo.environment["NVIM_APPNAME"]
            if !absolutePaths.isEmpty || nvimAppName != nil {
                var payload: [String: Any] = [
                    "files": absolutePaths,
                    "env": ProcessInfo.processInfo.environment,
                ]
                if let nvimAppName { payload["nvimAppName"] = nvimAppName }
                if let data = try? JSONSerialization.data(withJSONObject: payload),
                    let json = String(data: data, encoding: .utf8)
                {
                    DistributedNotificationCenter.default().post(
                        name: .veilOpenFiles, object: json
                    )
                }
            }
            existing.activate()
            // Terminate immediately — no resources to clean up, notification
            // already delivered, just get out of the way.
            exit(0)
        }

        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(handleOpenFilesNotification(_:)),
            name: .veilOpenFiles, object: nil
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
        if !initialCliArgs.isEmpty {
            // Cold start: macOS detected file arguments matching registered
            // document types. The same files are already in initialCliArgs
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
        if !initialCliArgs.isEmpty {
            doc.nvimArgs = initialCliArgs
            initialCliArgs = []
        }
        NSDocumentController.shared.addDocument(doc)
        doc.makeWindowControllers()
        doc.showWindows()
    }

    @objc private func handleOpenFilesNotification(_ notification: Notification) {
        guard let json = notification.object as? String,
            let data = json.data(using: .utf8),
            let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        let files = payload["files"] as? [String] ?? []
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
        doc.nvimArgs = files
        doc.nvimEnv = env
        NSDocumentController.shared.addDocument(doc)
        doc.makeWindowControllers()
        doc.showWindows()
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
