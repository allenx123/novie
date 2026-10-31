import Foundation

/// Speaks the line protocol MCPBridge speaks, over a real Unix socket, so MCPServer is
/// tested exactly as a connected agent drives it.
private final class MCPTestClient {
    private let fd: Int32
    private var reader: LineReader

    init(socketPath: String) throws {
        // Everything happens on a local before the stored properties are set, so the
        // sockaddr closure never captures a half-initialised client.
        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else { throw TestError("socket() failed") }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        guard socketPath.utf8.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            Darwin.close(sock)
            throw TestError("socket path too long")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            buf.copyBytes(from: socketPath.utf8)
            buf[socketPath.utf8.count] = 0
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(sock, $0, len) }
        }
        guard rc == 0 else {
            Darwin.close(sock)
            throw TestError("connect failed: \(String(cString: strerror(errno)))")
        }
        var on: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        fd = sock
        reader = LineReader(fd: sock)
    }

    func send(_ object: [String: Any]) { writeLine(fd, object) }

    func receive() -> [String: Any]? {
        guard let line = reader.next() else { return nil }
        return try? JSONSerialization.jsonObject(with: line) as? [String: Any]
    }

    /// Sends the greeting and returns the server's answer.
    @discardableResult
    func hello(token: String, client: String = "a test") -> [String: Any]? {
        send(["hello": token, "client": client])
        return receive()
    }

    /// One `computer` call: sends it and waits for the reply.
    func computer(_ actions: [[String: Any]]?, id: Int = 1) -> [String: Any]? {
        var args = [String: Any]()
        if let actions { args["actions"] = actions }
        send(["id": id, "call": "computer", "args": args])
        return receive()
    }

    /// Writes raw bytes, for testing what a malformed client does.
    func sendRaw(_ text: String) { writeAll(fd, [UInt8](text.utf8)) }

    func close() { Darwin.close(fd) }
}

/// The text block of a tool reply.
private func replyText(_ reply: [String: Any]?) -> String {
    guard let content = reply?["content"] as? [[String: Any]] else { return "" }
    for item in content where item["type"] as? String == "text" {
        return item["text"] as? String ?? ""
    }
    return ""
}

/// True if the reply carries a screenshot.
private func hasImage(_ reply: [String: Any]?) -> Bool {
    guard let content = reply?["content"] as? [[String: Any]] else { return false }
    return content.contains { $0["type"] as? String == "image" }
}

private func isError(_ reply: [String: Any]?) -> Bool { reply?["isError"] as? Bool ?? false }

/// Starts a server on a fresh run directory, runs the body, then tears it down.
private func withServer(allowed: Bool = true,
                        host: FakeHost,
                        _ body: (MCPServer, String, String) throws -> Void) throws {
    let was = UserDefaults.standard.object(forKey: MCPServer.defaultsKey)
    UserDefaults.standard.set(allowed, forKey: MCPServer.defaultsKey)
    defer {
        if let was { UserDefaults.standard.set(was, forKey: MCPServer.defaultsKey) }
        else { UserDefaults.standard.removeObject(forKey: MCPServer.defaultsKey) }
    }
    let dir = TempDir("mcp")
    defer { dir.cleanup() }
    let server = MCPServer(host: host, runDir: dir.url)
    try server.start()
    defer { server.stop() }
    let socketPath = MCPServer.socketPath(in: dir.url)
    let token = (try? String(contentsOfFile: MCPServer.tokenPath(in: dir.url), encoding: .utf8)) ?? ""
    try body(server, socketPath, token.trimmingCharacters(in: .whitespacesAndNewlines))
}

func mcpServerTests(_ t: TestRunner) {

    t.suite("MCPServer: the socket and token live next to each other in the run directory") {
        let dir = URL(fileURLWithPath: "/tmp/novie-example", isDirectory: true)
        t.equal(MCPServer.socketPath(in: dir), "/tmp/novie-example/mcp.sock", "the socket path")
        t.equal(MCPServer.tokenPath(in: dir), "/tmp/novie-example/mcp.token", "the token path")
    }

    t.suite("MCPServer: one call may play for ten minutes") {
        t.equal(MCPServer.callBudget, 600, "the documented budget")
    }

    t.suite("MCPServer: start writes a private token and listens") {
        let host = FakeHost(input: FakeInput())
        try withServer(host: host) { _, socketPath, token in
            t.equal(token.count, 64, "the token should be 32 random bytes as hex")
            t.expect(token.allSatisfy { $0.isHexDigit }, "and be hex")
            t.expect(FileManager.default.fileExists(atPath: socketPath), "the socket should exist")

            let attrs = try FileManager.default.attributesOfItem(
                atPath: MCPServer.tokenPath(in: URL(fileURLWithPath: socketPath).deletingLastPathComponent()))
            t.equal((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600,
                    "the token should only be readable by this user")
        }
    }

    t.suite("MCPServer: stop removes the socket and the token") {
        let host = FakeHost(input: FakeInput())
        let dir = TempDir("mcps")
        defer { dir.cleanup() }
        let was = UserDefaults.standard.bool(forKey: MCPServer.defaultsKey)
        UserDefaults.standard.set(true, forKey: MCPServer.defaultsKey)
        defer { UserDefaults.standard.set(was, forKey: MCPServer.defaultsKey) }
        let server = MCPServer(host: host, runDir: dir.url)
        try server.start()
        t.expect(FileManager.default.fileExists(atPath: MCPServer.socketPath(in: dir.url)),
                 "the socket should be there while it runs")
        server.stop()
        t.expect(!FileManager.default.fileExists(atPath: MCPServer.socketPath(in: dir.url)),
                 "the socket should be gone after stop")
        t.expect(!FileManager.default.fileExists(atPath: MCPServer.tokenPath(in: dir.url)),
                 "and so should the token")
        server.stop()  // stopping twice shouldn't crash
    }

    // MARK: the greeting

    t.suite("MCPServer: the right token is let in") {
        let host = FakeHost(input: FakeInput())
        try withServer(host: host) { _, socketPath, token in
            let client = try MCPTestClient(socketPath: socketPath)
            defer { client.close() }
            let answer = client.hello(token: token, client: "Claude")
            t.equal(answer?["ok"] as? Bool, true, "the greeting should be accepted")
            t.expect(waitUntil { host.noted.contains("MCP client connected: Claude") },
                     "and the window should say who connected, got \(host.noted)")
        }
    }

    t.suite("MCPServer: a client with no name is still let in") {
        let host = FakeHost(input: FakeInput())
        try withServer(host: host) { _, socketPath, token in
            let client = try MCPTestClient(socketPath: socketPath)
            defer { client.close() }
            client.send(["hello": token])
            t.equal(client.receive()?["ok"] as? Bool, true, "the greeting should be accepted")
            t.expect(waitUntil { host.noted.contains("MCP client connected: an agent") },
                     "and be described generically, got \(host.noted)")
        }
    }

    t.suite("MCPServer: a wrong token is refused") {
        let host = FakeHost(input: FakeInput())
        try withServer(host: host) { _, socketPath, _ in
            let client = try MCPTestClient(socketPath: socketPath)
            defer { client.close() }
            let answer = client.hello(token: "0000")
            t.expect((answer?["error"] as? String)?.contains("rejected the connection token") == true,
                     "a bad token should be refused, got \(String(describing: answer))")
        }
    }

    t.suite("MCPServer: a greeting with no token is refused") {
        let host = FakeHost(input: FakeInput())
        try withServer(host: host) { _, socketPath, _ in
            let client = try MCPTestClient(socketPath: socketPath)
            defer { client.close() }
            client.send(["client": "nameless"])
            t.expect((client.receive()?["error"] as? String)?.contains("token") == true,
                     "no token should be refused")
        }
    }

    t.suite("MCPServer: connections are refused while MCP is turned off") {
        // It's off until the person allows it in the Novie menu.
        let host = FakeHost(input: FakeInput())
        try withServer(allowed: false, host: host) { _, socketPath, token in
            let client = try MCPTestClient(socketPath: socketPath)
            defer { client.close() }
            let answer = client.hello(token: token)
            t.expect((answer?["error"] as? String)?.contains("MCP access is turned off") == true,
                     "it should say MCP is off, got \(String(describing: answer))")
            t.expect(waitUntil { host.noted.contains { $0.contains("tried to connect") } },
                     "and the window should mention the attempt, got \(host.noted)")
        }
    }

    t.suite("MCPServer: a client that sends nothing is dropped") {
        let host = FakeHost(input: FakeInput())
        try withServer(host: host) { _, socketPath, _ in
            let client = try MCPTestClient(socketPath: socketPath)
            client.close()
            t.expect(true, "closing without a greeting shouldn't take the server down")
            // The server is still usable afterwards
            let second = try MCPTestClient(socketPath: socketPath)
            defer { second.close() }
            let token = (try? String(contentsOfFile: MCPServer.tokenPath(
                in: URL(fileURLWithPath: socketPath).deletingLastPathComponent()),
                encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            t.equal(second.hello(token: token)?["ok"] as? Bool, true,
                    "a later client should still be served")
        }
    }

    t.suite("MCPServer: a disconnect is noted in the window") {
        let host = FakeHost(input: FakeInput())
        try withServer(host: host) { _, socketPath, token in
            let client = try MCPTestClient(socketPath: socketPath)
            client.hello(token: token, client: "Goer")
            client.close()
            t.expect(waitUntil { host.noted.contains("MCP client disconnected: Goer") },
                     "the window should say the client left, got \(host.noted)")
        }
    }

    // MARK: the computer tool

    t.suite("MCPServer: an empty action list answers with just a screenshot") {
        let host = FakeHost(input: FakeInput())
        try withServer(host: host) { _, socketPath, token in
            let client = try MCPTestClient(socketPath: socketPath)
            defer { client.close() }
            client.hello(token: token)
            let reply = client.computer([])
            t.equal(isError(reply), false, "an empty list is not an error")
            t.expect(hasImage(reply), "it should come back with a screenshot")
            t.equal(replyText(reply),
                    "The VM's screen right now. The screen is 1280x800; "
                    + "screenshot pixels are the coordinates to click.",
                    "and describe the screen")
            t.equal(reply?["id"] as? Int, 1, "the id should be echoed back")
        }
    }

    t.suite("MCPServer: a missing actions list is the same as an empty one") {
        let host = FakeHost(input: FakeInput())
        try withServer(host: host) { _, socketPath, token in
            let client = try MCPTestClient(socketPath: socketPath)
            defer { client.close() }
            client.hello(token: token)
            t.equal(isError(client.computer(nil)), false, "no actions key means just look")
            client.send(["id": 2, "call": "computer", "args": ["actions": NSNull()]])
            t.equal(isError(client.receive()), false, "an explicit null is the same")
        }
    }

    t.suite("MCPServer: actions are played into the VM and reported") {
        let input = FakeInput()
        let host = FakeHost(input: input)
        try withServer(host: host) { _, socketPath, token in
            let client = try MCPTestClient(socketPath: socketPath)
            defer { client.close() }
            client.hello(token: token)
            let reply = client.computer([["action": "left_click", "coordinate": [100, 200]],
                                         ["action": "type", "text": "hi"]])
            t.equal(isError(reply), false, "a good list is not an error")
            t.expect(hasImage(reply), "and comes back with a screenshot")
            t.expect(replyText(reply).hasPrefix("Ran all 2 actions."),
                     "it should say what it ran, got: \(replyText(reply))")
            t.equal(input.buttonTrail, [0, 1, 0], "the click should have reached the VM")
            t.equal(input.typedText, "hi", "and so should the typing")
        }
    }

    t.suite("MCPServer: one action is reported in the singular") {
        let host = FakeHost(input: FakeInput())
        try withServer(host: host) { _, socketPath, token in
            let client = try MCPTestClient(socketPath: socketPath)
            defer { client.close() }
            client.hello(token: token)
            let reply = client.computer([["action": "screenshot"]])
            t.expect(replyText(reply).hasPrefix("Ran all 1 action."),
                     "one action, not \"1 actions\", got: \(replyText(reply))")
        }
    }

    t.suite("MCPServer: a bad action is reported with a screenshot") {
        let host = FakeHost(input: FakeInput())
        try withServer(host: host) { _, socketPath, token in
            let client = try MCPTestClient(socketPath: socketPath)
            defer { client.close() }
            client.hello(token: token)
            let reply = client.computer([["action": "mouse_move", "coordinate": [1, 1]],
                                         ["action": "fly"]])
            t.equal(isError(reply), true, "a bad action is an error")
            t.expect(hasImage(reply), "but the screenshot still shows where it got to")
            let text = replyText(reply)
            t.expect(text.contains("Ran 1 action of 2"), "it should say how far it got, got: \(text)")
            t.expect(text.contains("unknown action \"fly\""), "and why it stopped, got: \(text)")
            t.expect(text.contains("Nothing after that was sent"),
                     "and that the rest was not played, got: \(text)")
        }
    }

    t.suite("MCPServer: an unknown tool is refused") {
        let host = FakeHost(input: FakeInput())
        try withServer(host: host) { _, socketPath, token in
            let client = try MCPTestClient(socketPath: socketPath)
            defer { client.close() }
            client.hello(token: token)
            client.send(["id": 7, "call": "teleport", "args": [:] as [String: Any]])
            let reply = client.receive()
            t.equal(isError(reply), true, "an unknown tool is an error")
            t.equal(replyText(reply), "Unknown tool: teleport", "naming the tool")
            t.equal(reply?["id"] as? Int, 7, "with the id echoed")
        }
    }

    t.suite("MCPServer: a malformed actions argument is explained") {
        let host = FakeHost(input: FakeInput())
        try withServer(host: host) { _, socketPath, token in
            let client = try MCPTestClient(socketPath: socketPath)
            defer { client.close() }
            client.hello(token: token)

            client.send(["id": 1, "call": "computer", "args": ["actions": "left_click"]])
            t.expect(replyText(client.receive()).contains("actions must be a list of objects"),
                     "a string instead of a list should be explained")

            client.send(["id": 2, "call": "computer", "args": ["actions": ["left_click"]]])
            t.expect(replyText(client.receive()).contains("actions must be a list of objects"),
                     "a list of strings should be explained too")
        }
    }

    t.suite("MCPServer: a client gets nothing while the person has control") {
        // Take Control wins, and it's the first thing checked: no input and no screenshot.
        let host = FakeHost(input: nil)
        host.refusal = "You have control of the VM — release it to let agents back in."
        try withServer(host: host) { _, socketPath, token in
            let client = try MCPTestClient(socketPath: socketPath)
            defer { client.close() }
            client.hello(token: token)
            let reply = client.computer([["action": "left_click", "coordinate": [1, 1]]])
            t.equal(isError(reply), true, "it should be refused")
            t.expect(!hasImage(reply), "and get no screenshot at all")
            t.equal(replyText(reply), host.refusal, "with the window's own reason")
        }
    }

    t.suite("MCPServer: taking control mid-list stops it and withholds the screenshot") {
        let input = FakeInput()
        let host = FakeHost(input: input)
        let queries = NSCounter()
        host.onInputQuery = {
            // Let the call start, then take control a few checkpoints in
            if queries.next() > 3 { host.input = nil }
        }
        host.refusal = "You have control of the VM."
        try withServer(host: host) { _, socketPath, token in
            let client = try MCPTestClient(socketPath: socketPath)
            defer { client.close() }
            client.hello(token: token)
            let reply = client.computer([["action": "left_click", "coordinate": [1, 1]],
                                         ["action": "left_click", "coordinate": [2, 2]],
                                         ["action": "left_click", "coordinate": [3, 3]],
                                         ["action": "left_click", "coordinate": [4, 4]]])
            t.equal(isError(reply), true, "being interrupted is an error")
            t.expect(!hasImage(reply), "the screen is theirs, so no screenshot")
            let text = replyText(reply)
            t.expect(text.contains("You have control of the VM."),
                     "it should give the window's reason, got: \(text)")
            t.expect(text.contains("then stopped") || text == host.refusal,
                     "and say it stopped part-way, got: \(text)")
        }
    }

    t.suite("MCPServer: a call with no frame yet explains there's no screenshot") {
        let host = FakeHost(input: FakeInput())
        host.screenshot = nil
        try withServer(host: host) { _, socketPath, token in
            let client = try MCPTestClient(socketPath: socketPath)
            defer { client.close() }
            client.hello(token: token)
            let reply = client.computer([])
            t.equal(isError(reply), true, "no screenshot is an error")
            t.expect(!hasImage(reply), "and there is no image to send")
            t.expect(replyText(reply).contains("No frame from the VM's display"),
                     "it should say the VM may still be starting, got: \(replyText(reply))")
        }
    }

    t.suite("MCPServer: a display with no size yet is left out of the report") {
        let host = FakeHost(input: FakeInput(width: 0, height: 0))
        try withServer(host: host) { _, socketPath, token in
            let client = try MCPTestClient(socketPath: socketPath)
            defer { client.close() }
            client.hello(token: token)
            let reply = client.computer([])
            t.equal(replyText(reply), "The VM's screen right now.",
                    "with no size known, no size is claimed")
        }
    }

    t.suite("MCPServer: the pointer carries over between calls") {
        // An action with no coordinate should go on from where the last call left off,
        // not jump to the top-left corner.
        let input = FakeInput()
        let host = FakeHost(input: input)
        try withServer(host: host) { _, socketPath, token in
            let client = try MCPTestClient(socketPath: socketPath)
            defer { client.close() }
            client.hello(token: token)
            _ = client.computer([["action": "mouse_move", "coordinate": [640, 400]]], id: 1)
            input.reset()
            _ = client.computer([["action": "left_click"]], id: 2)
            t.equal(input.positions.map { [$0.0, $0.1] }, [[640, 400], [640, 400]],
                    "the second call's click should land where the first left the pointer")
        }
    }

    t.suite("MCPServer: only one call plays at a time") {
        // Two clients mustn't be able to fight over the pointer.
        let host = FakeHost(input: FakeInput())
        try withServer(host: host) { _, socketPath, token in
            let first = try MCPTestClient(socketPath: socketPath)
            let second = try MCPTestClient(socketPath: socketPath)
            defer { first.close(); second.close() }
            first.hello(token: token, client: "one")
            second.hello(token: token, client: "two")

            // A call long enough to still be playing when the second arrives
            first.send(["id": 1, "call": "computer",
                        "args": ["actions": [["action": "wait", "duration": 1.5]]]])
            usleep(300_000)
            let refused = second.computer([["action": "left_click", "coordinate": [1, 1]]], id: 2)
            t.equal(isError(refused), true, "the second call should be refused")
            t.equal(replyText(refused),
                    "Another computer call is still playing its actions. Wait for it to finish.",
                    "and say why")
            t.equal(isError(first.receive()), false, "the first call should still finish cleanly")
        }
    }

    t.suite("MCPServer: a junk line is skipped and the connection carries on") {
        let host = FakeHost(input: FakeInput())
        try withServer(host: host) { _, socketPath, token in
            let client = try MCPTestClient(socketPath: socketPath)
            defer { client.close() }
            client.hello(token: token)
            client.sendRaw("this is not json\n")
            let reply = client.computer([], id: 5)
            t.equal(reply?["id"] as? Int, 5, "the next real call should still be answered")
            t.equal(isError(reply), false, "and work normally")
        }
    }

    t.suite("MCPServer: a call with no id still gets an answer") {
        let host = FakeHost(input: FakeInput())
        try withServer(host: host) { _, socketPath, token in
            let client = try MCPTestClient(socketPath: socketPath)
            defer { client.close() }
            client.hello(token: token)
            client.send(["call": "computer", "args": ["actions": []]])
            let reply = client.receive()
            t.expect(reply?["id"] is NSNull, "the id should come back null")
            t.equal(isError(reply), false, "and the call should work")
        }
    }

    t.suite("MCPServer: a request with no call name is refused") {
        let host = FakeHost(input: FakeInput())
        try withServer(host: host) { _, socketPath, token in
            let client = try MCPTestClient(socketPath: socketPath)
            defer { client.close() }
            client.hello(token: token)
            client.send(["id": 1, "args": [:] as [String: Any]])
            t.equal(replyText(client.receive()), "Unknown tool: ", "an empty tool name is unknown")
        }
    }

    t.suite("MCPServer: the window is told what a client is doing") {
        let host = FakeHost(input: FakeInput())
        try withServer(host: host) { _, socketPath, token in
            let client = try MCPTestClient(socketPath: socketPath)
            defer { client.close() }
            client.hello(token: token)
            _ = client.computer([["action": "mouse_move", "coordinate": [1, 1]]])
            t.expect(waitUntil { host.noted.contains("MCP: running 1 action…") },
                     "it should say what is about to run, got \(host.noted)")
            t.expect(waitUntil { host.noted.contains("MCP: ran 1 action") },
                     "and what ran, got \(host.noted)")
            _ = client.computer([], id: 2)
            t.expect(waitUntil { host.noted.contains("MCP: screenshot") },
                     "a bare screenshot is noted as one, got \(host.noted)")
        }
    }

    t.suite("MCPServer: MCPError carries its message") {
        let error = MCPServer.MCPError("the MCP socket path is too long")
        t.equal(error.errorDescription, "the MCP socket path is too long", "as its description")
        t.equal(error.localizedDescription, "the MCP socket path is too long", "and localized")
    }

    t.suite("MCPInput: says either where input goes or why it can't") {
        // Read back through a host, which is how MCPServer actually asks.
        let display = FakeInput()
        let host = FakeHost(input: display)
        switch host.mcpInput() {
        case .ready(let target): t.expect(target === display, "ready should carry the display")
        case .refused(let why): t.expect(false, "it shouldn't be refused: \(why)")
        }

        host.input = nil
        host.refusal = "You have control of the VM."
        switch host.mcpInput() {
        case .ready: t.expect(false, "with no display it shouldn't be ready")
        case .refused(let why):
            t.equal(why, "You have control of the VM.", "refused should carry the reason")
        }
    }
}

/// A thread-safe counter for the host callbacks, which fire on the server's threads.
final class NSCounter {
    private var value = 0
    private let lock = NSLock()
    func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
}
