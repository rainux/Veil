import Foundation
import MessagePack

enum RpcMessage: Sendable {
    case response(msgid: UInt32, error: MessagePackValue, result: MessagePackValue)
    case notification(method: String, params: MessagePackValue)
    case request(msgid: UInt32, method: String, params: MessagePackValue)
}

actor MsgpackRpc {
    private var nextMsgid: UInt32 = 0
    private var pendingRequests: [UInt32: CheckedContinuation<(error: MessagePackValue, result: MessagePackValue), Never>] = [:]
    private var eventContinuation: AsyncStream<RpcMessage>.Continuation?

    private let inPipe: FileHandle   // write to nvim stdin
    private let outPipe: FileHandle  // read from nvim stdout

    lazy var notifications: AsyncStream<RpcMessage> = {
        AsyncStream { continuation in
            self.eventContinuation = continuation
        }
    }()

    init(inPipe: FileHandle, outPipe: FileHandle) {
        self.inPipe = inPipe
        self.outPipe = outPipe
    }

    func start() async {
        var accumulated = Data()
        for await chunk in outPipe.asyncDataChunks {
            accumulated.append(chunk)
            let messages: [RpcMessage]
            do {
                messages = try Self.decodeAccumulated(data: &accumulated)
            } catch {
                continue
            }
            for message in messages {
                switch message {
                case .response(let msgid, let error, let result):
                    if let continuation = pendingRequests.removeValue(forKey: msgid) {
                        continuation.resume(returning: (error, result))
                    }
                case .notification, .request:
                    eventContinuation?.yield(message)
                }
            }
        }
        eventContinuation?.finish()
        for (_, continuation) in pendingRequests {
            continuation.resume(returning: (error: .string("channel closed"), result: .nil))
        }
        pendingRequests.removeAll()
    }

    func request(method: String, params: [MessagePackValue]) async -> (error: MessagePackValue, result: MessagePackValue) {
        let msgid = nextMsgid
        nextMsgid += 1
        let data = Self.encodeRequest(msgid: msgid, method: method, params: params)

        return await withCheckedContinuation { continuation in
            pendingRequests[msgid] = continuation
            inPipe.write(data)
        }
    }

    // MARK: - Static encode/decode (testable without actor)

    nonisolated static func encodeRequest(msgid: UInt32, method: String, params: [MessagePackValue]) -> Data {
        let message: MessagePackValue = .array([
            .uint(0),
            .uint(UInt64(msgid)),
            .string(method),
            .array(params),
        ])
        return pack(message)
    }

    nonisolated static func decode(data: Data) throws -> [RpcMessage] {
        var mutableData = data
        return try decodeAccumulated(data: &mutableData)
    }

    nonisolated static func decodeAccumulated(data: inout Data) throws -> [RpcMessage] {
        var messages: [RpcMessage] = []
        while !data.isEmpty {
            let value: MessagePackValue
            let remainder: Data
            do {
                (value, remainder) = try unpack(data)
            } catch {
                // Incomplete data — stop decoding, leave data as-is
                break
            }
            data = Data(remainder)
            guard let array = value.arrayValue, array.count >= 3 else { continue }
            guard let type = array[0].uint64Value else { continue }

            switch type {
            case 0: // request
                guard array.count >= 4,
                      let msgid = array[1].uint64Value,
                      let method = array[2].stringValue else { continue }
                messages.append(.request(msgid: UInt32(msgid), method: method, params: array[3]))
            case 1: // response
                guard array.count >= 4,
                      let msgid = array[1].uint64Value else { continue }
                messages.append(.response(msgid: UInt32(msgid), error: array[2], result: array[3]))
            case 2: // notification
                guard let method = array[1].stringValue else { continue }
                messages.append(.notification(method: method, params: array[2]))
            default:
                continue
            }
        }
        return messages
    }
}

extension MessagePackValue {
    nonisolated var intValue: Int {
        switch self {
        case .int(let v): return Int(v)
        case .uint(let v): return Int(v)
        default: return 0
        }
    }
}

extension FileHandle {
    nonisolated var asyncDataChunks: AsyncStream<Data> {
        AsyncStream { continuation in
            self.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    continuation.finish()
                    return
                }
                continuation.yield(data)
            }
        }
    }
}
