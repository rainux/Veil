import Foundation

final class NvimProcess: @unchecked Sendable {
    nonisolated(unsafe) let stdinPipe = Pipe()
    nonisolated(unsafe) let stdoutPipe = Pipe()
    nonisolated(unsafe) let stderrPipe = Pipe()

    private nonisolated(unsafe) var _process: Process?
    private let _processLock = NSLock()
    private let nvimPath: String
    private let cwd: String
    private let appName: String
    private let additionalEnv: [String: String]

    var isRunning: Bool {
        _processLock.lock()
        defer { _processLock.unlock() }
        return _process?.isRunning ?? false
    }

    init(
        nvimPath: String = "",
        cwd: String = NSHomeDirectory(),
        appName: String = "nvim",
        additionalEnv: [String: String] = [:]
    ) {
        self.nvimPath = nvimPath
        self.cwd = cwd
        self.appName = appName
        self.additionalEnv = additionalEnv
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
        var env = ProcessInfo.processInfo.environment
        env["NVIM_APPNAME"] = appName
        env.merge(additionalEnv) { _, new in new }
        process.environment = env
        process.arguments = ["--embed"]
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

    // MARK: - Binary resolution

    private func resolveNvimBinary() -> String {
        if !nvimPath.isEmpty, FileManager.default.isExecutableFile(atPath: nvimPath) {
            return nvimPath
        }
        if let path = Self.findInPath("nvim") { return path }
        for candidate in ["/opt/homebrew/bin/nvim", "/usr/local/bin/nvim"] {
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return "/usr/local/bin/nvim"
    }

    private static func findInPath(_ binary: String) -> String? {
        guard let pathString = ProcessInfo.processInfo.environment["PATH"] else { return nil }
        for dir in pathString.split(separator: ":") {
            let candidate = "\(dir)/\(binary)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

}
