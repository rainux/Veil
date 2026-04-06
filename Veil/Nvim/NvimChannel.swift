import AppKit
import Foundation
import MessagePack

actor NvimChannel {
    private var process: NvimProcess?
    private var rpc: MsgpackRpc?
    private var transport: RpcTransport?
    private var eventContinuation: AsyncStream<[NvimEvent]>.Continuation?
    private var rpcTask: Task<Void, Never>?
    private(set) var isRemote = false

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

        let pipeTransport = PipeTransport(
            writePipe: proc.stdinPipe.fileHandleForWriting,
            readPipe: proc.stdoutPipe.fileHandleForReading
        )
        self.transport = pipeTransport
        startRpcEventLoop(transport: pipeTransport)
    }

    /// Connect to a remote nvim instance over TCP. No local process is spawned.
    func connectRemote(host: String, port: UInt16) async throws {
        isRemote = true
        let socketTransport = SocketTransport(host: host, port: port)
        try await socketTransport.waitUntilReady()
        self.transport = socketTransport
        startRpcEventLoop(transport: socketTransport)
    }

    private func startRpcEventLoop(transport: RpcTransport) {
        let rpc = MsgpackRpc(transport: transport)
        self.rpc = rpc

        rpcTask = Task {
            // Access notifications before starting the receive loop so the
            // lazy var is initialized (and the continuation is stored) on the
            // MsgpackRpc actor.
            let notifications = await rpc.notifications
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await rpc.start() }
                group.addTask {
                    for await message in notifications {
                        switch message {
                        case .notification(let method, let params):
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
                            } else if method == "VeilAppDebugCopy" {
                                await self.yieldBatch([.veilDebugCopy])
                            }
                        case .request(let msgid, let method, let params):
                            await self.handleRequest(
                                rpc: rpc, msgid: msgid, method: method, params: params)
                        case .response:
                            break
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
                    .string("ext_tabline"): .bool(true),
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

    private func handleRequest(
        rpc: MsgpackRpc, msgid: UInt32, method: String, params: MessagePackValue
    ) async {
        switch method {
        case "VeilAppClipboardSet":
            guard let args = params.arrayValue, args.count >= 2,
                let lines = args[0].arrayValue?.compactMap({ $0.stringValue }),
                args[1].stringValue != nil
            else {
                await rpc.respond(
                    msgid: msgid,
                    error: .string("VeilAppClipboardSet: invalid params"),
                    result: .nil)
                return
            }
            let text = lines.joined(separator: "\n")
            writePasteboard(text)
            await rpc.respond(msgid: msgid, result: .bool(true))

        case "VeilAppClipboardGet":
            let text = readPasteboard()
            let lines: [MessagePackValue] = text.split(
                separator: "\n", omittingEmptySubsequences: false
            ).map { .string(String($0)) }
            let regtype: MessagePackValue = text.hasSuffix("\n") ? .string("V") : .string("v")
            await rpc.respond(msgid: msgid, result: .array([.array(lines), regtype]))

        default:
            await rpc.respond(
                msgid: msgid,
                error: .string("Unknown method: \(method)"),
                result: .nil)
        }
    }

    /// Write a string to the system pasteboard. Must run on the main thread.
    private nonisolated func writePasteboard(_ text: String) {
        DispatchQueue.main.sync {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    /// Read a string from the system pasteboard. Must run on the main thread.
    private nonisolated func readPasteboard() -> String {
        DispatchQueue.main.sync {
            NSPasteboard.general.string(forType: .string) ?? ""
        }
    }

    var nvimPath: String { process?.resolvedNvimPath ?? "" }

    func stop() {
        rpcTask?.cancel()
        transport?.close()
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
