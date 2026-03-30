import AppKit

@MainActor
final class ProfilePicker {
    /// Shows an NSMenu popup near `view` and calls `completion` with the chosen profile.
    /// If only one (or zero) profiles are available, completes immediately with the default.
    static func pick(relativeTo view: NSView, completion: @escaping (Profile) -> Void) {
        let profiles = Profile.availableProfiles()
        guard profiles.count > 1 else {
            completion(.default)
            return
        }

        let menu = NSMenu()
        menu.autoenablesItems = false

        for profile in profiles {
            let item = NSMenuItem(title: profile.displayName, action: nil, keyEquivalent: "")
            item.isEnabled = true
            // Store profile via representedObject
            item.representedObject = profile
            menu.addItem(item)
        }

        // Use a temporary target/action approach via NSMenu popup
        let handler = ProfileMenuHandler(profiles: profiles, completion: completion)
        for (index, item) in menu.items.enumerated() {
            item.target = handler
            item.action = #selector(ProfileMenuHandler.selectProfile(_:))
            item.tag = index
        }

        // Retain handler until menu is dismissed
        objc_setAssociatedObject(menu, &ProfilePicker.handlerKey, handler, .OBJC_ASSOCIATION_RETAIN)

        let location = NSPoint(x: 0, y: view.bounds.height)
        menu.popUp(positioning: nil, at: location, in: view)
    }

    private static var handlerKey: UInt8 = 0
}

// MARK: - Internal menu handler

private final class ProfileMenuHandler: NSObject {
    private let profiles: [Profile]
    private let completion: (Profile) -> Void

    init(profiles: [Profile], completion: @escaping (Profile) -> Void) {
        self.profiles = profiles
        self.completion = completion
    }

    @objc func selectProfile(_ sender: NSMenuItem) {
        let index = sender.tag
        guard index >= 0, index < profiles.count else { return }
        completion(profiles[index])
    }
}
