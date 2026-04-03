import Foundation
import MessagePack

actor NvimChannel {
    private var process: NvimProcess?
    private var rpc: MsgpackRpc?
    private var eventContinuation: AsyncStream<[NvimEvent]>.Continuation?
    private var rpcTask: Task<Void, Never>?

    /// Events are delivered in batches (one array per redraw notification)
    /// to reduce actor isolation boundary crossings. A single redraw with
    /// 50 grid_line events becomes one yield instead of 50.
    let events: AsyncStream<[NvimEvent]>

    init() {
        let (stream, continuation) = AsyncStream<[NvimEvent]>.makeStream()
        self.events = stream
        self.eventContinuation = continuation
    }

    func start(
        nvimPath: String = "", cwd: String = NSHomeDirectory(), appName: String = "nvim",
        extraArgs: [String] = [], env: [String: String]? = nil
    ) async throws {
        let proc = NvimProcess(
            nvimPath: nvimPath, cwd: cwd, appName: appName,
            customEnv: env, extraArgs: extraArgs)
        try proc.start()
        self.process = proc

        let rpc = MsgpackRpc(
            inPipe: proc.stdinPipe.fileHandleForWriting,
            outPipe: proc.stdoutPipe.fileHandleForReading
        )
        self.rpc = rpc

        // Access notifications before spawning the task so the lazy var is
        // initialized (and the continuation is stored) on the actor.
        let notifications = await rpc.notifications

        rpcTask = Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await rpc.start() }
                group.addTask {
                    for await message in notifications {
                        guard case .notification(let method, let params) = message else { continue }
                        if method == "redraw" {
                            guard let args = params.arrayValue else { continue }
                            let events = NvimEvent.parse(redrawArgs: args)
                            // Yield entire redraw batch at once to amortize
                            // actor isolation crossing overhead.
                            if !events.isEmpty {
                                await self.yieldBatch(events)
                            }
                        } else if method == "VeilAppBufChanged" {
                            await self.yieldBatch([.veilBufChanged])
                        } else if method == "VeilAppDebugToggle" {
                            await self.yieldBatch([.veilDebugToggle])
                        }
                    }
                }
                await group.waitForAll()
            }
            self.finishEvents()
        }
    }

    // Isolated helpers called from the unstructured Task above
    private func yieldBatch(_ events: [NvimEvent]) {
        eventContinuation?.yield(events)
    }

    private func finishEvents() {
        eventContinuation?.finish()
    }

    func uiAttach(width: Int, height: Int) async throws {
        let (error, _) = await request(
            "nvim_ui_attach",
            params: [
                .int(Int64(width)), .int(Int64(height)),
                .map([
                    .string("rgb"): .bool(true),
                    .string("ext_linegrid"): .bool(true),
                    .string("ext_tabline"): .bool(false),
                    .string("ext_multigrid"): .bool(false),
                ]),
            ])
        if case .string(let msg) = error { throw NvimChannelError.rpcError(msg) }
        if error != .nil { throw NvimChannelError.rpcError("ui_attach failed: \(error)") }
    }

    func send(key: String) async {
        _ = await request("nvim_input", params: [.string(key)])
    }

    func command(_ cmd: String) async throws {
        let (error, _) = await request("nvim_command", params: [.string(cmd)])
        if case .string(let msg) = error { throw NvimChannelError.rpcError(msg) }
        if error != .nil { throw NvimChannelError.rpcError("command failed: \(error)") }
    }

    func request(_ method: String, params: [MessagePackValue]) async -> (
        error: MessagePackValue, result: MessagePackValue
    ) {
        guard let rpc else { return (.string("not connected"), .nil) }
        return await rpc.request(method: method, params: params)
    }

    func uiTryResize(width: Int, height: Int) async {
        _ = await request("nvim_ui_try_resize", params: [.int(Int64(width)), .int(Int64(height))])
    }

    func inputMouse(button: String, action: String, modifier: String, grid: Int, row: Int, col: Int)
        async
    {
        _ = await request(
            "nvim_input_mouse",
            params: [
                .string(button), .string(action), .string(modifier),
                .int(Int64(grid)), .int(Int64(row)), .int(Int64(col)),
            ])
    }

    func stop() {
        rpcTask?.cancel()
        process?.stop()
        eventContinuation?.finish()
    }
}

nonisolated enum NvimChannelError: Error, LocalizedError {
    case rpcError(String)
    var errorDescription: String? {
        switch self {
        case .rpcError(let msg): return "Neovim RPC error: \(msg)"
        }
    }
}
