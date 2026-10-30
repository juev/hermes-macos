import Testing
@testable import HermesCore

@Suite("JSON values")
struct JSONValueTests {
    @Test("A frame survives a round trip")
    func roundTrip() throws {
        let value: JSONValue = [
            "type": "assistant.message",
            "seq": 12,
            "ok": true,
            "payload": ["text": "héllo\n«мир»", "usage": ["input": 10, "cost": 0.25]],
            "empty": .null
        ]
        let back = try JSONValue.decode(value.encoded())
        #expect(back == value)
    }

    @Test("Reading a frame")
    func reading() {
        let value: JSONValue = ["a": 1, "b": "x", "c": true, "d": [1, 2], "e": .null]
        #expect(value["a"]?.intValue == 1)
        #expect(value["a"]?.doubleValue == 1)
        #expect(value["b"]?.stringValue == "x")
        #expect(value["c"]?.boolValue == true)
        #expect(value["d"]?.arrayValue?.count == 2)
        #expect(value["e"] == .null)
        #expect(value["missing"] == nil)
    }

    @Test("A number written as a string still reads as a number")
    func numericString() {
        #expect((JSONValue.string("1700000000"))["nope"] == nil)
        #expect(JSONValue.string("1700000000").numericValue == 1_700_000_000)
        #expect(JSONValue.number(1_700_000_000).numericValue == 1_700_000_000)
    }

    @Test("An id that arrives as a number reads as a string")
    func scalarStrings() {
        #expect(JSONValue.number(42).scalarString == "42")
        #expect(JSONValue.number(42.5).scalarString == "42.5")
        #expect(JSONValue.string("abc").scalarString == "abc")
        #expect(JSONValue.bool(true).scalarString == "true")
        #expect(JSONValue.null.scalarString == nil)
    }

    @Test("An integer is kept whole")
    func integers() {
        #expect(JSONValue.number(9_007_199_254_740_992).int64Value == 9_007_199_254_740_992)
        #expect(JSONValue.string("5").intValue == nil)
        #expect(JSONValue.number(1.5).intValue == nil)
    }
}

@Suite("Frames of the socket")
struct FrameTests {
    @Test("A notification is an event")
    func event() throws {
        let frame = try JSONValue.decode(#"""
        {"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready","session_id":"s-1","seq":7,"payload":{"replay_epoch":"e-9","session_authority":true,"heartbeat":true}}}
        """#)
        guard case .event(let event)? = Frame.parse(frame) else {
            Issue.record("Not an event")
            return
        }
        #expect(event.type == "gateway.ready")
        #expect(event.sessionID == "s-1")
        #expect(event.seq == 7)
        let ready = GatewayReady(payload: event.payload)
        #expect(ready.replayEpoch == "e-9")
        #expect(ready.sessionAuthority)
        #expect(ready.heartbeat)
    }

    @Test("An event without a payload still parses")
    func bareEvent() throws {
        let frame = try JSONValue.decode(#"{"method":"event","params":{"type":"turn.cancelled"}}"#)
        guard case .event(let event)? = Frame.parse(frame) else {
            Issue.record("Not an event")
            return
        }
        #expect(event.type == "turn.cancelled")
        #expect(event.sessionID == nil)
        #expect(event.payload.isEmpty)
    }

    @Test("A call from the server waits for an answer")
    func serverRequest() throws {
        let frame = try JSONValue.decode(#"{"jsonrpc":"2.0","id":"srv-1","method":"approval.request","params":{"kind":"command"}}"#)
        guard case .request(let request)? = Frame.parse(frame) else {
            Issue.record("Not a request")
            return
        }
        #expect(request.id == "srv-1")
        #expect(request.method == "approval.request")
        #expect(request.params["kind"]?.stringValue == "command")
    }

    @Test("The answer to a call")
    func results() throws {
        let ok = try JSONValue.decode(#"{"jsonrpc":"2.0","id":"a1","result":{"sessions":[]}}"#)
        #expect(Frame.parse(ok) == .result(id: "a1", value: ["sessions": []]))
        #expect(Frame.parse(try JSONValue.decode(#"{"jsonrpc":"2.0","id":"a2","result":null}"#)) == .result(id: "a2", value: .null))

        let failed = try JSONValue.decode(#"{"jsonrpc":"2.0","id":"a3","error":{"code":-32602,"message":"bad params","data":{"field":"session_id"}}}"#)
        guard case .failure(let id, let error)? = Frame.parse(failed) else {
            Issue.record("Not a failure")
            return
        }
        #expect(id == "a3")
        #expect(error.code == -32602)
        #expect(error.message == "bad params")
        #expect(error.data?["field"]?.stringValue == "session_id")
    }

    @Test("A frame that is none of the four kinds is dropped")
    func unknown() throws {
        #expect(Frame.parse(try JSONValue.decode(#"{"jsonrpc":"2.0","method":"event"}"#)) == nil)
        #expect(Frame.parse(try JSONValue.decode(#"["not","a","frame"]"#)) == nil)
        #expect(Frame.parse(try JSONValue.decode(#""bare""#)) == nil)
    }

    @Test("Answers to a server request")
    func answers() {
        #expect(Frame.answer(id: "srv-1") == ["jsonrpc": "2.0", "id": "srv-1", "result": .object([:])])
        #expect(Frame.answer(id: "srv-1", error: "denied") == [
            "jsonrpc": "2.0", "id": "srv-1", "error": ["code": -32000, "message": "denied"]
        ])
    }

    @Test("A call names itself and carries its parameters")
    func outgoing() throws {
        let request = RPCRequest(id: "a7", method: "gateway.ping")
        let frame = try JSONValue.decode(request.frame.encoded())
        #expect(frame["jsonrpc"]?.stringValue == "2.0")
        #expect(frame["id"]?.stringValue == "a7")
        #expect(frame["method"]?.stringValue == "gateway.ping")
        #expect(frame["params"]?.objectValue?.isEmpty == true)
    }
}
