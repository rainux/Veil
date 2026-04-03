import Foundation

nonisolated final class NvimProcess: @unchecked Sendable {
    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()

    private nonisolated(unsafe) var _process: Process?
    private let _processLock = NSLock()
    private let nvimPath: String
    private let cwd: String
    private let appName: String
    private let customEnv: [String: String]?
    private let additionalEnv: [String: String]
    private let extraArgs: [String]

    var isRunning: Bool {
        _processLock.lock()
        defer { _processLock.unlock() }
        return _process?.isRunning ?? false
    }

    init(
        nvimPath: String = "",
        cwd: String = NSHomeDirectory(),
        appName: String = "nvim",
        customEnv: [String: String]? = nil,
        additionalEnv: [String: String] = [:],
        extraArgs: [String] = []
    ) {
        self.nvimPath = nvimPath
        self.cwd = cwd
        self.appName = appName
        self.customEnv = customEnv
        self.additionalEnv = additionalEnv
        self.extraArgs = extraArgs
    }

    func start() throws {
        let process = Process()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.qualityOfService = .userInteractive
        let binary = resolveNvimBinary()
        process.executableURL = URL(fileURLWithPath: binary)
        var env = customEnv ?? Self.cachedEnv
        env["NVIM_APPNAME"] = appName
        env.merge(additionalEnv) { _, new in new }
        process.environment = env
        process.arguments = ["--embed"] + extraArgs
        try process.run()
        _processLock.lock()
        _process = process
        _processLock.unlock()
    }

    func stop() {
        _processLock.lock()
        let process = _process
        _processLock.unlock()
        guard let process, process.isRunning else { return }
        stdinPipe.fileHandleForWriting.closeFile()
        DispatchQueue.global().async {
            process.waitUntilExit()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if process.isRunning { process.terminate() }
        }
    }

    // MARK: - Login shell environment
    //
    // When launched from Spotlight/Dock, the app inherits launchd's minimal
    // PATH which lacks Homebrew, nvm, cargo, etc. We spawn the user's login
    // shell once to capture their full environment (especially PATH), so nvim
    // and its plugins (e.g. Copilot.lua needing Node.js) can find their tools.
    // The result is cached — subsequent windows reuse it with no overhead.

    private static var _cachedEnv: [String: String]?
    private static let envLock = NSLock()

    static var cachedEnv: [String: String] {
        envLock.lock()
        if let env = _cachedEnv {
            envLock.unlock()
            return env
        }
        envLock.unlock()
        // Capture outside lock — this spawns a shell process and may take seconds
        let env = captureLoginShellEnvironment()
        envLock.lock()
        if _cachedEnv == nil { _cachedEnv = env }
        let result = _cachedEnv!
        envLock.unlock()
        return result
    }

    static func updateCachedEnv(from cliEnv: [String: String]) {
        envLock.lock()
        _cachedEnv = cliEnv
        _cachedEnv?.removeValue(forKey: "NVIM_APPNAME")
        envLock.unlock()
    }

    /// Trigger eager loading of cachedEnv in background.
    static func warmUpEnvironment() { _ = cachedEnv }

    private static func captureLoginShellEnvironment() -> [String: String] {
        captureShellEnvironment(shellArgs: ["-l"])
    }

    private static func captureInteractiveShellEnvironment() -> [String: String] {
        captureShellEnvironment(shellArgs: ["-l", "-i"])
    }

    private static func captureShellEnvironment(shellArgs: [String]) -> [String: String] {
        let shellPath = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shellPath)
        let marker = UUID().uuidString
        process.arguments = shellArgs + ["-c", "echo \(marker) && env"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return ProcessInfo.processInfo.environment
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8),
            let markerRange = output.range(of: marker)
        else {
            return ProcessInfo.processInfo.environment
        }
        let envString = output[markerRange.upperBound...].trimmingCharacters(
            in: .whitespacesAndNewlines)
        var env: [String: String] = [:]
        for line in envString.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2 { env[String(parts[0])] = String(parts[1]) }
        }
        return env.isEmpty ? ProcessInfo.processInfo.environment : env
    }

    // MARK: - Binary resolution

    private static let nvimPathDefaultsKey = "cachedNvimPath"

    /// Resolve the nvim binary path with a layered strategy that balances
    /// reliability and performance:
    ///
    /// 1. UserDefaults cache — zero overhead on subsequent launches. Verified
    ///    on each launch (executable check); stale entries trigger re-detection.
    /// 2. Login shell (-l) — fast, covers Homebrew/Nix/Cargo users who
    ///    configure PATH in .zprofile or .zshenv.
    /// 3. Interactive login shell (-l -i) — slow, but picks up tools like mise
    ///    and nvm that only activate in .zshrc. The cost is paid once; the
    ///    result is cached for all future launches.
    /// 4. Well-known paths — last resort if both shells fail (e.g. broken
    ///    shell config). Checks Homebrew (ARM/Intel) and MacPorts locations.
    private func resolveNvimBinary() -> String {
        // Explicit path from caller
        if !nvimPath.isEmpty, FileManager.default.isExecutableFile(atPath: nvimPath) {
            return nvimPath
        }

        // Cached path from previous detection
        if let cached = UserDefaults.standard.string(forKey: Self.nvimPathDefaultsKey),
            FileManager.default.isExecutableFile(atPath: cached)
        {
            return cached
        }

        // Phase 1 (fast): cachedEnv lazily spawns a login shell (-l) on first access,
        // covers users who set PATH in .zprofile
        let loginEnv = Self.cachedEnv
        if let path = Self.findInPath("nvim", in: loginEnv["PATH"]) {
            Self.cacheNvimPath(path)
            return path
        }

        // Phase 2: interactive login shell (slow, covers mise/nvm in .zshrc)
        let interactiveEnv = Self.captureInteractiveShellEnvironment()
        if let path = Self.findInPath("nvim", in: interactiveEnv["PATH"]) {
            Self.envLock.lock()
            Self._cachedEnv = interactiveEnv
            Self.envLock.unlock()
            Self.cacheNvimPath(path)
            return path
        }

        // Well-known candidates
        for candidate in ["/opt/homebrew/bin/nvim", "/usr/local/bin/nvim", "/opt/local/bin/nvim"] {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                Self.cacheNvimPath(candidate)
                return candidate
            }
        }
        return "/usr/local/bin/nvim"
    }

    private static func cacheNvimPath(_ path: String) {
        UserDefaults.standard.set(path, forKey: nvimPathDefaultsKey)
    }

    private static func findInPath(_ binary: String, in pathString: String?) -> String? {
        guard let pathString else { return nil }
        for dir in pathString.split(separator: ":") {
            let candidate = "\(dir)/\(binary)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

}
