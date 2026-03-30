import Cocoa

@main
class AppDelegate: NSObject, NSApplicationDelegate {
    // CLI args to pass to nvim. Filter out macOS/Xcode injected arguments
    // (e.g. -NSDocumentRevisionsDebugMode, -ApplePersistenceIgnoreState).
    private var initialCliArgs: [String] = {
        var args: [String] = []
        var skip = false
        for arg in ProcessInfo.processInfo.arguments.dropFirst() {
            if skip { skip = false; continue }
            if arg.hasPrefix("-NS") || arg.hasPrefix("-Apple") {
                skip = true  // skip this flag and its value
                continue
            }
            args.append(arg)
        }
        return args
    }()

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        Task.detached { NvimProcess.warmUpEnvironment() }
        addProfilePickerMenuItem()
        NSApp.activate(ignoringOtherApps: true)

        // Defer default window creation — if openFiles: is called (Finder launch),
        // a window will already exist, so we skip the default one.
        DispatchQueue.main.async {
            if NSDocumentController.shared.documents.isEmpty {
                self.createWindow(profile: Profile.default)
            }
        }
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let doc = WindowDocument()
        doc.profile = Profile.default
        doc.nvimArgs = filenames
        NSDocumentController.shared.addDocument(doc)
        doc.makeWindowControllers()
        doc.showWindows()
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
        guard let window = NSApp.keyWindow, let view = window.contentView else {
            // No key window — fall back to showing picker relative to the menu bar.
            // Create a temporary invisible view anchored at screen origin.
            let tempView = NSView(frame: .zero)
            NSApp.mainWindow?.contentView?.addSubview(tempView)
            ProfilePicker.pick(relativeTo: tempView) { [weak tempView] profile in
                tempView?.removeFromSuperview()
                self.createWindow(profile: profile)
            }
            return
        }
        ProfilePicker.pick(relativeTo: view) { profile in
            self.createWindow(profile: profile)
        }
    }

    /// Creates and shows a new WindowDocument with the given profile.
    func createWindow(profile: Profile) {
        let doc = WindowDocument()
        doc.profile = profile
        if !initialCliArgs.isEmpty {
            doc.nvimArgs = initialCliArgs
            initialCliArgs = []
        }
        NSDocumentController.shared.addDocument(doc)
        doc.makeWindowControllers()
        doc.showWindows()
    }

    // MARK: - Menu Setup

    private func addProfilePickerMenuItem() {
        guard let mainMenu = NSApp.mainMenu,
              let fileMenu = mainMenu.items.first(where: { $0.title == "File" })?.submenu
        else { return }

        // Find "New" item (Cmd+N) and insert our item after it.
        let newItemIndex = fileMenu.items.firstIndex(where: { $0.keyEquivalent == "n" && $0.keyEquivalentModifierMask == .command }) ?? 0

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
