import AppKit

@MainActor
final class ProfilePicker {
    static func pick(in parentWindow: NSWindow?, completion: @escaping (Profile) -> Void) {
        let profiles = Profile.availableProfiles()
        guard profiles.count > 1 else {
            completion(.default)
            return
        }
        ListPicker.pick(
            title: "Select Profile",
            items: profiles,
            titleFor: { $0.displayName },
            in: parentWindow
        ) { profile in
            if let profile { completion(profile) }
        }
    }
}
