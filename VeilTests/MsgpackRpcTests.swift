import XCTest
import MessagePack
@testable import Veil

final class MsgpackRpcTests: XCTestCase {

    func testEncodeRequest() throws {
        let data = MsgpackRpc.encodeRequest(
            msgid: 1,
            method: "nvim_ui_attach",
            params: [.int(80), .int(24), .map(["rgb": .bool(true)])]
        )
        let unpacked = try unpack(data)
        let array = unpacked.value.arrayValue!
        XCTAssertEqual(array[0], .uint(0))
        XCTAssertEqual(array[1], .uint(1))
        XCTAssertEqual(array[2], .string("nvim_ui_attach"))
        XCTAssertEqual(array[3].arrayValue?.count, 3)
    }

    func testDecodeResponse() throws {
        let response: MessagePackValue = .array([.uint(1), .uint(1), .nil, .string("ok")])
        let data = pack(response)
        let messages = try MsgpackRpc.decode(data: data)
        XCTAssertEqual(messages.count, 1)
        if case .response(let msgid, let error, let result) = messages[0] {
            XCTAssertEqual(msgid, 1)
            XCTAssertEqual(error, .nil)
            XCTAssertEqual(result, .string("ok"))
        } else {
            XCTFail("Expected response message")
        }
    }

    func testDecodeNotification() throws {
        let notification: MessagePackValue = .array([.uint(2), .string("redraw"), .array([])])
        let data = pack(notification)
        let messages = try MsgpackRpc.decode(data: data)
        XCTAssertEqual(messages.count, 1)
        if case .notification(let method, let params) = messages[0] {
            XCTAssertEqual(method, "redraw")
            XCTAssertEqual(params, .array([]))
        } else {
            XCTFail("Expected notification message")
        }
    }

    func testDecodeMultipleMessagesInOneChunk() throws {
        let msg1: MessagePackValue = .array([.uint(1), .uint(1), .nil, .bool(true)])
        let msg2: MessagePackValue = .array([.uint(2), .string("flush"), .array([])])
        var data = pack(msg1)
        data.append(pack(msg2))
        let messages = try MsgpackRpc.decode(data: data)
        XCTAssertEqual(messages.count, 2)
    }

    func testDecodePartialData() throws {
        let full: MessagePackValue = .array([.uint(1), .uint(1), .nil, .string("ok")])
        let data = pack(full)
        let partial = Data(data.prefix(data.count / 2))
        let messages = try MsgpackRpc.decode(data: partial)
        XCTAssertTrue(messages.isEmpty)
    }
}
