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
        createWindow(profile: Profile.default)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ aNotification: Notification) {}

    // Tracks which documents should close as part of a Cmd+Q quit attempt.
    // When all tracked documents have closed, the app terminates.
    // Documents closed normally (Cmd+W) are not in this set, so they
    // don't trigger app termination.
    var quittingDocuments: Set<ObjectIdentifier> = []

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let documents = NSDocumentController.shared.documents.compactMap { $0 as? WindowDocument }
        if documents.isEmpty { return .terminateNow }

        quittingDocuments = Set(documents.map { ObjectIdentifier($0) })
        for doc in documents {
            Task { @MainActor in
                try? await doc.channel.command("confirm qa")
            }
        }
        return .terminateCancel
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
