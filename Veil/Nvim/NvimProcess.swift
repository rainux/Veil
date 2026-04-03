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
        let shellPath = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shellPath)
        let marker = UUID().uuidString
        // Login shell only (-l). Skip interactive (-i) which is usually slow.
        // Login profile provides the correct PATH.
        process.arguments = ["-l", "-c", "echo \(marker) && env"]
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

    private func resolveNvimBinary() -> String {
        if !nvimPath.isEmpty, FileManager.default.isExecutableFile(atPath: nvimPath) {
            return nvimPath
        }
        // Search using cachedEnv PATH (from user's login shell), not the
        // process environment PATH (launchd's minimal PATH that lacks
        // Homebrew, nix, cargo, etc.).
        if let path = Self.findInPath("nvim", in: Self.cachedEnv["PATH"]) { return path }
        for candidate in ["/opt/homebrew/bin/nvim", "/usr/local/bin/nvim"] {
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return "/usr/local/bin/nvim"
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
