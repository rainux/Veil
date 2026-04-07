import AppKit

@MainActor
final class RemotePicker {
    /// Shows a picker listing saved remote connections from veil.toml.
    /// Calls `completion` with the chosen address, or `nil` if the user
    /// picks "Connect to new address..." (caller should show text input).
    /// If no saved entries exist, calls `completion(nil)` immediately.
    static func pick(in parentWindow: NSWindow?, completion: @escaping (String?) -> Void) {
        let entries = VeilConfig.current.remote ?? []
        guard !entries.isEmpty else {
            completion(nil)
            return
        }

        let sentinel = RemoteEntry(name: "Connect to new address\u{2026}", address: "")
        let items = entries + [sentinel]

        ListPicker.pick(
            title: "Remote Neovim",
            items: items,
            titleFor: { $0.name },
            subtitleFor: { $0.address.isEmpty ? "" : $0.address },
            in: parentWindow
        ) { selected in
            guard let selected else { return }
            completion(selected.address.isEmpty ? nil : selected.address)
        }
    }
}
