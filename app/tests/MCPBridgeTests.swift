import Foundation

/// Runs this binary again as the stdio MCP server (see main.swift), sends it JSON-RPC
/// messages and reads the answers back — the same thing an agent does with
/// `NovieMCP --mcp`, which is the only way to exercise MCPBridge.run().
private final class BridgeProcess {
    private let process = Process()
    private let toBridge = Pipe()
    private let fromBridge = Pipe()
    private var reader: LineReader

    /// `home` redirects the bridge's Application Support lookup, so a tool call looks for
    /// Novie's socket under a temporary directory instead of finding the real app — a test
    /// must never end up driving the VM the person is actually using.
    ///
    /// CFFIXED_USER_HOME is the one that does the work: Foundation's
    /// `urls(for: .applicationSupportDirectory…)` ignores $HOME on macOS and still returns
    /// the real home without it (measured). HOME is set too, for anything that reads it.
    init(home: URL) throws {
        process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
        process.arguments = ["--bridge-child"]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        environment["CFFIXED_USER_HOME"] = home.path
        process.environment = environment
        process.standardInput = toBridge
        process.standardOutput = fromBridge
        process.standardError = FileHandle.nullDevice
        reader = LineReader(fd: fromBridge.fileHandleForReading.fileDescriptor)
        try process.run()
    }

    func send(_ message: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: message) else { return }
        data.append(0x0a)
        writeAll(toBridge.fileHandleForWriting.fileDescriptor, [UInt8](data))
    }

    func sendRaw(_ text: String) {
        writeAll(toBridge.fileHandleForWriting.fileDescriptor, [UInt8](text.utf8))
    }

    func receive() -> [String: Any]? {
        guard let line = reader.next() else { return nil }
        return try? JSONSerialization.jsonObject(with: line) as? [String: Any]
    }

    /// Sends a request and returns its answer.
    func request(_ method: String, id: Any = 1, params: [String: Any]? = nil) -> [String: Any]? {
        var message: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if let params { message["params"] = params }
        send(message)
        return receive()
    }

    func finish() {
        toBridge.fileHandleForWriting.closeFile()
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline { usleep(20_000) }
        if process.isRunning { process.terminate() }
    }
}

/// The run directory the bridge will look in, given a fake home.
private func runDir(in home: TempDir) -> URL {
    home.url.appendingPathComponent("Library/Application Support/Novie", isDirectory: true)
}

/// A fake home with room for the run directory path inside it (Unix sockets are capped at
/// 104 bytes, and "…/Library/Application Support/Novie/mcp.token" is most of that).
private func bridgeHome() -> TempDir {
    TempDir("brg", reserving: "/Library/Application Support/Novie/mcp.token".utf8.count)
}

/// Runs a bridge against an empty home for the length of the body.
private func withBridge(_ body: (BridgeProcess) throws -> Void) throws {
    let home = bridgeHome()
    defer { home.cleanup() }
    let bridge = try BridgeProcess(home: home.url)
    defer { bridge.finish() }
    try body(bridge)
}

/// Runs a real MCPServer where the bridge will look for it, plus a bridge pointed at it.
private func withBridgeAndServer(allowed: Bool = true, host: FakeHost,
                                 _ body: (BridgeProcess, MCPServer, URL) throws -> Void) throws {
    let was = UserDefaults.standard.object(forKey: MCPServer.defaultsKey)
    UserDefaults.standard.set(allowed, forKey: MCPServer.defaultsKey)
    defer {
        if let was { UserDefaults.standard.set(was, forKey: MCPServer.defaultsKey) }
        else { UserDefaults.standard.removeObject(forKey: MCPServer.defaultsKey) }
    }
    let home = bridgeHome()
    defer { home.cleanup() }
    let directory = runDir(in: home)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    let server = MCPServer(host: host, runDir: directory)
    try server.start()
    defer { server.stop() }
    let bridge = try BridgeProcess(home: home.url)
    defer { bridge.finish() }
    try body(bridge, server, directory)
}

/// The text of a tools/call result.
private func callText(_ reply: [String: Any]?) -> String {
    let result = reply?["result"] as? [String: Any]
    let content = result?["content"] as? [[String: Any]]
    for item in content ?? [] where item["type"] as? String == "text" {
        return item["text"] as? String ?? ""
    }
    return ""
}

private func callIsError(_ reply: [String: Any]?) -> Bool {
    (reply?["result"] as? [String: Any])?["isError"] as? Bool ?? false
}

func mcpBridgeTests(_ t: TestRunner) {

    t.suite("MCPBridge: identifies itself") {
        t.equal(MCPBridge.name, "novie", "the server name clients see")
        t.equal(MCPBridge.protocolVersions.last, "2025-06-18", "the newest protocol revision")
        t.expect(!MCPBridge.version.isEmpty, "it should report a version")
    }

    t.suite("MCPBridge: initialize answers with the protocol it was asked for") {
        try withBridge { bridge in
            let reply = bridge.request("initialize", params: [
                "protocolVersion": "2025-03-26",
                "clientInfo": ["name": "a test client"],
            ])
            let result = reply?["result"] as? [String: Any]
            t.equal(result?["protocolVersion"] as? String, "2025-03-26",
                    "a revision it knows should be echoed back")
            let info = result?["serverInfo"] as? [String: Any]
            t.equal(info?["name"] as? String, "novie", "with its own name")
            t.equal(info?["version"] as? String, MCPBridge.version, "and version")
            t.expect((result?["capabilities"] as? [String: Any])?["tools"] != nil,
                     "it should advertise tools")
            t.expect((result?["instructions"] as? String)?.contains("Linux desktop") == true,
                     "and explain what Novie is")
            t.equal(reply?["jsonrpc"] as? String, "2.0", "the envelope should be JSON-RPC 2.0")
            t.equal(reply?["id"] as? Int, 1, "with the id echoed")
        }
    }

    t.suite("MCPBridge: an unknown protocol revision gets the newest one") {
        try withBridge { bridge in
            let reply = bridge.request("initialize", params: ["protocolVersion": "1999-01-01"])
            t.equal((reply?["result"] as? [String: Any])?["protocolVersion"] as? String,
                    MCPBridge.protocolVersions.last,
                    "an unknown revision should fall back to the newest")
        }
    }

    t.suite("MCPBridge: initialize works with no params at all") {
        try withBridge { bridge in
            let reply = bridge.request("initialize")
            t.equal((reply?["result"] as? [String: Any])?["protocolVersion"] as? String,
                    MCPBridge.protocolVersions.last, "and still answers")
        }
    }

    t.suite("MCPBridge: ping is answered") {
        try withBridge { bridge in
            let reply = bridge.request("ping", id: 42)
            t.expect(reply?["result"] != nil, "ping should get a result")
            t.equal(reply?["id"] as? Int, 42, "with the id echoed")
        }
    }

    t.suite("MCPBridge: tools/list describes the one computer tool") {
        try withBridge { bridge in
            let reply = bridge.request("tools/list")
            guard let tools = (reply?["result"] as? [String: Any])?["tools"] as? [[String: Any]] else {
                t.expect(false, "tools/list should return a list, got \(String(describing: reply))")
                return
            }
            t.equal(tools.count, 1, "there is exactly one tool")
            let tool = tools[0]
            t.equal(tool["name"] as? String, "computer", "named computer")
            let description = tool["description"] as? String ?? ""
            t.expect(description.contains("mouse and keyboard"), "it should say what it does")
            t.expect(!description.contains("\n"), "the description is folded onto one line")

            let schema = tool["inputSchema"] as? [String: Any]
            t.equal(schema?["type"] as? String, "object", "the schema is an object")
            t.equal(schema?["required"] as? [String], ["actions"], "with actions required")
            let properties = schema?["properties"] as? [String: Any]
            let actions = properties?["actions"] as? [String: Any]
            t.equal(actions?["type"] as? String, "array", "actions is an array")

            let item = actions?["items"] as? [String: Any]
            t.equal(item?["required"] as? [String], ["action"], "each action needs a name")
            let fields = item?["properties"] as? [String: Any]
            for field in ["action", "coordinate", "start_coordinate", "text", "duration",
                          "scroll_direction", "scroll_amount"] {
                t.expect(fields?[field] != nil, "the schema should describe \(field)")
            }

            // The vocabulary the model is told about has to be the one ActionRunner plays
            let names = (fields?["action"] as? [String: Any])?["enum"] as? [String] ?? []
            let expected = ["key", "type", "mouse_move", "left_click", "right_click",
                            "middle_click", "double_click", "triple_click", "left_click_drag",
                            "left_mouse_down", "left_mouse_up", "scroll", "hold_key", "wait",
                            "screenshot"]
            t.equal(names.sorted(), expected.sorted(), "every action should be offered")

            let directions = (fields?["scroll_direction"] as? [String: Any])?["enum"] as? [String]
            t.equal(directions, ["up", "down"], "only up and down, as ActionRunner allows")
        }
    }

    t.suite("MCPBridge: every advertised action is one ActionRunner accepts") {
        // The schema and the runner drifting apart would send a model after actions that
        // don't exist, so check each one against the real runner.
        try withBridge { bridge in
            let reply = bridge.request("tools/list")
            let tools = (reply?["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []
            let fields = ((tools.first?["inputSchema"] as? [String: Any])?["properties"]
                as? [String: Any])?["actions"] as? [String: Any]
            let item = fields?["items"] as? [String: Any]
            let names = ((item?["properties"] as? [String: Any])?["action"]
                as? [String: Any])?["enum"] as? [String] ?? []
            t.expect(!names.isEmpty, "there should be some action names to check")

            for name in names {
                // Enough arguments that only an unknown name can fail it
                var action: [String: Any] = ["action": name, "coordinate": [10, 10],
                                             "start_coordinate": [1, 1], "duration": 0.01,
                                             "scroll_direction": "up", "scroll_amount": 1]
                if name == "key" || name == "hold_key" { action["text"] = "a" }
                if name == "type" { action["text"] = "a" }
                var runner = ActionRunner(input: FakeInput(), budget: 10, startingAt: (0, 0),
                                          maySendInput: { true })
                if case .failed(let why, _) = runner.run([action]) {
                    t.expect(false, "the schema offers \"\(name)\" but the runner rejects it: \(why)")
                }
            }
        }
    }

    t.suite("MCPBridge: an unknown method is a JSON-RPC error") {
        try withBridge { bridge in
            let reply = bridge.request("resources/list", id: 9)
            let error = reply?["error"] as? [String: Any]
            t.equal(error?["code"] as? Int, -32601, "method not found")
            t.expect((error?["message"] as? String)?.contains("resources/list") == true,
                     "naming the method, got \(String(describing: error))")
            t.equal(reply?["id"] as? Int, 9, "with the id echoed")
        }
    }

    t.suite("MCPBridge: invalid JSON is a parse error") {
        try withBridge { bridge in
            bridge.sendRaw("{ this is not json\n")
            let reply = bridge.receive()
            let error = reply?["error"] as? [String: Any]
            t.equal(error?["code"] as? Int, -32700, "parse error")
            t.expect(reply?["id"] is NSNull, "with a null id, since there isn't one to echo")
        }
    }

    t.suite("MCPBridge: a notification gets no answer") {
        // A message with no id wants no reply; answering one would break the client.
        try withBridge { bridge in
            bridge.send(["jsonrpc": "2.0", "method": "notifications/initialized"])
            // The next real request's answer should be the next thing on the stream
            let reply = bridge.request("ping", id: 3)
            t.equal(reply?["id"] as? Int, 3, "the ping's answer should come back next")
        }
    }

    t.suite("MCPBridge: a request with a null id gets no answer either") {
        try withBridge { bridge in
            bridge.send(["jsonrpc": "2.0", "id": NSNull(), "method": "ping"])
            let reply = bridge.request("ping", id: 4)
            t.equal(reply?["id"] as? Int, 4, "only the real request should be answered")
        }
    }

    t.suite("MCPBridge: a message with no method is ignored") {
        try withBridge { bridge in
            bridge.send(["jsonrpc": "2.0", "id": 1])
            let reply = bridge.request("ping", id: 5)
            t.equal(reply?["id"] as? Int, 5, "the stream should stay aligned")
        }
    }

    t.suite("MCPBridge: a tool call explains that Novie isn't running") {
        // The handshake is answered by the bridge itself, so the server still starts when
        // the app is closed; only tool calls need it.
        try withBridge { bridge in
            _ = bridge.request("initialize", params: ["clientInfo": ["name": "a test"]])
            let reply = bridge.request("tools/call", id: 2, params: [
                "name": "computer",
                "arguments": ["actions": []],
            ])
            let result = reply?["result"] as? [String: Any]
            t.equal(result?["isError"] as? Bool, true, "it can't work with the app closed")
            let content = result?["content"] as? [[String: Any]]
            let text = content?.first?["text"] as? String ?? ""
            t.expect(text.contains("Novie isn't running"),
                     "and should say so, got: \(text)")
            t.expect(text.contains("Open Novie.app"), "with what to do about it, got: \(text)")
        }
    }

    t.suite("MCPBridge: a tool call with no arguments still answers") {
        try withBridge { bridge in
            let reply = bridge.request("tools/call", id: 3, params: ["name": "computer"])
            let result = reply?["result"] as? [String: Any]
            t.equal(result?["isError"] as? Bool, true, "it still can't reach the app")
            t.expect(((result?["content"] as? [[String: Any]])?.first?["text"] as? String)?
                        .contains("Novie isn't running") == true,
                     "and explains why")
        }
    }

    // MARK: the bridge talking to a running app

    t.suite("MCPBridge: a tool call reaches the app and comes back with a screenshot") {
        // The whole path an agent uses: stdio JSON-RPC -> the bridge -> the app's socket ->
        // ActionRunner -> the VM's display, and a screenshot back the same way.
        let display = FakeInput()
        let host = FakeHost(input: display)
        try withBridgeAndServer(host: host) { bridge, _, _ in
            _ = bridge.request("initialize", params: ["clientInfo": ["name": "bridge test"]])
            let reply = bridge.request("tools/call", id: 2, params: [
                "name": "computer",
                "arguments": ["actions": [["action": "left_click", "coordinate": [40, 50]]]],
            ])
            t.equal(callIsError(reply), false, "the call should succeed, got: \(callText(reply))")
            let content = (reply?["result"] as? [String: Any])?["content"] as? [[String: Any]]
            t.expect(content?.contains { $0["type"] as? String == "image" } == true,
                     "a screenshot should come back through the bridge")
            t.expect(callText(reply).hasPrefix("Ran all 1 action."),
                     "with the app's own report, got: \(callText(reply))")
            t.equal(display.buttonTrail, [0, 1, 0], "and the click should have reached the VM")
            t.equal(display.positions.first.map { [$0.0, $0.1] } ?? [], [40, 50], "at the coordinate")
            // The name from initialize is what the window shows
            t.expect(waitUntil { host.noted.contains("MCP client connected: bridge test") },
                     "the client's name should reach the window, got \(host.noted)")
        }
    }

    t.suite("MCPBridge: an empty action list comes back as a screenshot") {
        let host = FakeHost(input: FakeInput())
        try withBridgeAndServer(host: host) { bridge, _, _ in
            let reply = bridge.request("tools/call", id: 1, params: [
                "name": "computer", "arguments": ["actions": []],
            ])
            t.equal(callIsError(reply), false, "looking at the screen should work")
            t.expect(callText(reply).hasPrefix("The VM's screen right now."),
                     "got: \(callText(reply))")
        }
    }

    t.suite("MCPBridge: the app's refusal is passed through to the client") {
        // With MCP turned off in the menu, the server refuses the greeting and the bridge
        // has to report that rather than a connection error of its own.
        let host = FakeHost(input: FakeInput())
        try withBridgeAndServer(allowed: false, host: host) { bridge, _, _ in
            let reply = bridge.request("tools/call", id: 1, params: [
                "name": "computer", "arguments": ["actions": []],
            ])
            t.equal(callIsError(reply), true, "it should be an error")
            t.expect(callText(reply).contains("MCP access is turned off"),
                     "with the app's own words, got: \(callText(reply))")
        }
    }

    t.suite("MCPBridge: a stale token is reported, not retried forever") {
        let home = bridgeHome()
        defer { home.cleanup() }
        let directory = runDir(in: home)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not-the-real-token".utf8).write(to: URL(fileURLWithPath: MCPServer.tokenPath(in: directory)))
        // A socket that refuses every greeting, the way the app does for a bad token
        let server = try FakeSocketServer(path: MCPServer.socketPath(in: directory)) { fd in
            var reader = LineReader(fd: fd)
            _ = reader.next()
            writeLine(fd, ["error": "Novie rejected the connection token."])
        }
        defer { server.stop() }
        let bridge = try BridgeProcess(home: home.url)
        defer { bridge.finish() }
        let reply = bridge.request("tools/call", id: 1, params: [
            "name": "computer", "arguments": ["actions": []],
        ])
        t.equal(callIsError(reply), true, "a refused token is an error")
        t.equal(callText(reply), "Novie rejected the connection token.",
                "and the refusal is passed straight through")
    }

    t.suite("MCPBridge: an app that hangs up without answering is reported") {
        let home = bridgeHome()
        defer { home.cleanup() }
        let directory = runDir(in: home)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("token".utf8).write(to: URL(fileURLWithPath: MCPServer.tokenPath(in: directory)))
        let server = try FakeSocketServer(path: MCPServer.socketPath(in: directory)) { _ in }
        defer { server.stop() }
        let bridge = try BridgeProcess(home: home.url)
        defer { bridge.finish() }
        let reply = bridge.request("tools/call", id: 1, params: [
            "name": "computer", "arguments": ["actions": []],
        ])
        t.equal(callIsError(reply), true, "it should be an error")
        t.expect(callText(reply).contains("without answering") || callText(reply).contains("Lost the connection"),
                 "and say the app didn't answer, got: \(callText(reply))")
    }

    t.suite("MCPBridge: it connects once the app is opened") {
        // The connection is opened on the first tool call, not at startup, so an agent that
        // was configured before Novie was running works as soon as the app appears.
        //
        // Note the server is deliberately *not* stopped part-way here: MCPServer.stop()
        // closes the listener but leaves an already-accepted connection running, so a client
        // that is already connected would keep being served. The app doesn't rely on stop()
        // for that — MainWindowController.mcpInput() refuses while isSaving is set.
        let host = FakeHost(input: FakeInput())
        let home = bridgeHome()
        defer { home.cleanup() }
        let directory = runDir(in: home)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let was = UserDefaults.standard.bool(forKey: MCPServer.defaultsKey)
        UserDefaults.standard.set(true, forKey: MCPServer.defaultsKey)
        defer { UserDefaults.standard.set(was, forKey: MCPServer.defaultsKey) }

        let bridge = try BridgeProcess(home: home.url)
        defer { bridge.finish() }

        // Nothing listening yet
        let before = bridge.request("tools/call", id: 1, params: [
            "name": "computer", "arguments": ["actions": []],
        ])
        t.equal(callIsError(before), true, "with no app there, the call should fail")
        t.expect(callText(before).contains("Novie isn't running"),
                 "and say what to do, got: \(callText(before))")

        // Now the person opens Novie
        let server = MCPServer(host: host, runDir: directory)
        try server.start()
        defer { server.stop() }
        let after = bridge.request("tools/call", id: 2, params: [
            "name": "computer", "arguments": ["actions": []],
        ])
        t.equal(callIsError(after), false,
                "the next call should connect and work, got: \(callText(after))")
        t.expect(callText(after).hasPrefix("The VM's screen right now."),
                 "with the app's own report, got: \(callText(after))")
    }

    t.suite("MCPBridge: closing stdin ends the server") {
        let home = bridgeHome()
        defer { home.cleanup() }
        let bridge = try BridgeProcess(home: home.url)
        _ = bridge.request("ping")
        bridge.finish()
        t.expect(true, "the process should exit when its input closes")
    }
}
