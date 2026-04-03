import Foundation

struct Profile: Codable, Hashable, Sendable {
    let name: String
    var displayName: String

    static let `default` = Profile(name: "nvim", displayName: "Default")

    func hash(into hasher: inout Hasher) { hasher.combine(name) }
    static func == (lhs: Profile, rhs: Profile) -> Bool { lhs.name == rhs.name }

    // MARK: - Profile Discovery

    /// Scans $XDG_CONFIG_HOME (or ~/.config/) for directories containing an nvim config.
    static func availableProfiles() -> [Profile] {
        let fm = FileManager.default
        let configURL: URL
        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            configURL = URL(fileURLWithPath: xdg)
        } else {
            configURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config")
        }

        guard
            let entries = try? fm.contentsOfDirectory(
                at: configURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return [.default]
        }

        var profiles: [Profile] = []

        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            let dirName = entry.lastPathComponent
            let hasNvimConfig =
                fm.fileExists(atPath: entry.appendingPathComponent("init.lua").path)
                || fm.fileExists(atPath: entry.appendingPathComponent("init.vim").path)
            if hasNvimConfig {
                let displayName = dirName == "nvim" ? "Default" : dirName
                profiles.append(Profile(name: dirName, displayName: displayName))
            }
        }

        // Always include default profile even if directory doesn't exist
        if !profiles.contains(.default) {
            profiles.insert(.default, at: 0)
        }

        return profiles.isEmpty ? [.default] : profiles
    }

}
