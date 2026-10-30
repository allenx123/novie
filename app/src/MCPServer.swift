import Foundation

/// Whether input may go to the VM right now, and where it goes.
enum MCPInput {
    case ready(VMInput)
    /// Why not — the person has taken control, or the VM's display isn't up yet.
    case refused(String)
}

/// The window actions an MCP client may drive. Every method is called on the main thread.
protocol MCPHost: AnyObject {
    /// The VM's display to play actions into, or why it can't be driven right now.
    func mcpInput() -> MCPInput
    func mcpScreenshotJPEG() -> Data?
    /// Shows in the window what a connected agent is doing, so the person can see it.
    func mcpNote(_ text: String)
}

/// Lets other agents work Novie's VM the way the person at the window does. It listens on a
/// Unix socket in the run directory (0700, so only this user reaches it); `NovieMCP --mcp`
/// connects to it and speaks MCP to the agent's stdio (see MCPBridge).
///
/// One request per line:  {"id": 1, "call": "computer", "args": {"actions": [...]}}
/// One reply per line:    {"id": 1, "content": [{"type": "text", "text": "…"}], "isError": false}
/// The first line a client sends is {"hello": "<token>", "client": "…"}; the token is the one
/// in `mcp.token` next to the socket.
final class MCPServer {
    /// Off until the person allows it in the Novie menu: a connected agent drives their VM.
    static let defaultsKey = "allowMCPConnections"
    static var isAllowed: Bool { UserDefaults.standard.bool(forKey: defaultsKey) }

    /// How long one `computer` call may spend playing its actions, in seconds.
    static let callBudget: TimeInterval = 600

    /// Time for the guest to finish redrawing before the screenshot is taken. It only covers
    /// a repaint, so an action list that opens a window should still end with its own `wait`.
    private static let settle: TimeInterval = 0.5

    static func socketPath(in runDir: URL) -> String { runDir.appendingPathComponent("mcp.sock").path }
    static func tokenPath(in runDir: URL) -> String { runDir.appendingPathComponent("mcp.token").path }

    private weak var host: MCPHost?
    private let runDir: URL
    private var token = ""
    private var listener: Int32 = -1
    private var stopped = false
    /// Held while a `computer` call is playing, so two clients can't fight over the pointer
    private var running = false
    /// Where the last call left the pointer, so an action with no coordinate in the next one
    /// carries on from there instead of jumping to the top-left corner
    private var pointer = (x: 0, y: 0)
    private let lock = NSLock()

    init(host: MCPHost, runDir: URL) {
        self.host = host
        self.runDir = runDir
    }

    func start() throws {
        let path = Self.socketPath(in: runDir)
        let fm = FileManager.default
        try? fm.removeItem(atPath: path)
        // Shared secret, in case the run directory's permissions are ever loosened. Written
        // before the socket exists, so a client never finds the socket with a stale token.
        token = Self.randomHex(32)
        fm.createFile(atPath: Self.tokenPath(in: runDir), contents: Data(token.utf8),
                      attributes: [.posixPermissions: 0o600])
        guard path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            throw MCPError("the MCP socket path is too long")
        }
        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else { throw MCPError("socket() failed") }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            buf.copyBytes(from: path.utf8)
            buf[path.utf8.count] = 0
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(sock, $0, len) }
        }
        guard rc == 0, listen(sock, 4) == 0 else {
            let reason = String(cString: strerror(errno))
            close(sock)
            throw MCPError("could not listen on \(path): \(reason)")
        }
        chmod(path, 0o600)
        listener = sock
        let t = Thread { [weak self] in self?.acceptLoop(sock) }
        t.name = "MCP server"
        t.start()
    }

    func stop() {
        lock.lock()
        stopped = true
        let sock = listener
        listener = -1
        lock.unlock()
        if sock >= 0 { close(sock) }  // makes accept() return
        try? FileManager.default.removeItem(atPath: Self.socketPath(in: runDir))
        try? FileManager.default.removeItem(atPath: Self.tokenPath(in: runDir))
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func acceptLoop(_ sock: Int32) {
        while !isStopped {
            let conn = accept(sock, nil, nil)
            if conn < 0 {
                if isStopped { return }
                if errno == EINTR { continue }
                return
            }
            let t = Thread { [weak self] in
                self?.serve(conn)
                close(conn)
            }
            t.name = "MCP connection"
            t.start()
        }
    }

    // MARK: one connection

    private func serve(_ fd: Int32) {
        var reader = LineReader(fd: fd)
        guard let hello = reader.next(), let greeting = Self.parse(hello) else { return }
        guard Self.isAllowed else {
            send(fd, ["error": "MCP access is turned off in Novie (Novie → Allow MCP Connections)."])
            onMain { self.host?.mcpNote("An MCP client tried to connect. Turn on Novie → Allow MCP Connections to let it in.") }
            return
        }
        guard let given = greeting["hello"] as? String, !token.isEmpty, given == token else {
            send(fd, ["error": "Novie rejected the connection token. Quit and reopen Novie, then try again."])
            return
        }
        let name = (greeting["client"] as? String) ?? "an agent"
        onMain { self.host?.mcpNote("MCP client connected: \(name)") }
        send(fd, ["ok": true])
        defer { onMain { self.host?.mcpNote("MCP client disconnected: \(name)") } }

        while let line = reader.next() {
            guard let request = Self.parse(line) else { continue }
            let id = request["id"] ?? NSNull()
            var reply = call(request["call"] as? String ?? "",
                             request["args"] as? [String: Any] ?? [:])
            reply["id"] = id
            send(fd, reply)
        }
    }

    // MARK: the one tool

    private func call(_ name: String, _ args: [String: Any]) -> [String: Any] {
        guard name == "computer" else { return Self.failed("Unknown tool: \(name)") }

        // The person's Take Control wins, and it's the first thing checked: while they have
        // the mouse and keyboard, a client gets neither input nor a look at the screen.
        // Anything else that stands in the way (the display not up yet) is reported here too.
        let target: VMInput
        switch onMain({ self.host?.mcpInput() ?? .refused("Novie is shutting down.") }) {
        case .refused(let why): return Self.failed(why)
        case .ready(let input): target = input
        }

        guard let actions = Self.actions(args["actions"]) else {
            return Self.failed("""
                actions must be a list of objects, each with an "action" name — for example \
                [{"action": "left_click", "coordinate": [640, 400]}]. Pass [] for just a screenshot.
                """)
        }
        guard claim() else {
            return Self.failed("Another computer call is still playing its actions. Wait for it to finish.")
        }
        defer { release() }

        var outcome = ActionRunner.Stop.completed
        if !actions.isEmpty {
            onMain { self.host?.mcpNote("MCP: running \(actions.count) action\(actions.count == 1 ? "" : "s")…") }
            var runner = ActionRunner(input: target, budget: Self.callBudget,
                                      startingAt: lastPointer(),
                                      maySendInput: { [weak self] in self?.stillAllowed() ?? false })
            outcome = runner.run(actions)
            remember(runner.position)
            Thread.sleep(forTimeInterval: Self.settle)
        }

        // Being interrupted mid-list is the same refusal as finding the VM unavailable at
        // the start, and it answers with the reason the window gives now rather than a guess:
        // usually the person taking control, in which case they get no screenshot either.
        if case .interrupted(let after) = outcome {
            onMain { self.host?.mcpNote("MCP: stopped after \(Self.count(after)) of \(actions.count)") }
            var why = "the VM stopped accepting input"
            if case .refused(let reason) = onMain({ self.host?.mcpInput() ?? .refused("Novie is shutting down.") }) {
                why = reason
            }
            guard after > 0 else { return Self.failed(why) }
            return Self.failed("Ran \(Self.count(after)) of \(actions.count), then stopped. " + why)
        }

        onMain { self.host?.mcpNote(Self.note(for: outcome, of: actions.count)) }
        guard let jpeg = onMain({ self.host?.mcpScreenshotJPEG() }) else {
            return Self.failed(Self.report(outcome, of: actions.count, screen: nil)
                + "\n\nNo frame from the VM's display, so there's no screenshot — it may still be starting.")
        }
        let size = target.screenSize
        let screen = size.width > 0 ? size : nil
        let isError: Bool
        switch outcome {
        case .completed: isError = false
        default: isError = true
        }
        return ["isError": isError, "content": [
            ["type": "text", "text": Self.report(outcome, of: actions.count, screen: screen)],
            ["type": "image", "data": jpeg.base64EncodedString(), "mimeType": "image/jpeg"],
        ]]
    }

    /// Still allowed to send input: asked between actions, so the person's Take Control stops
    /// a list part-way rather than only before it starts.
    private func stillAllowed() -> Bool {
        if case .ready = onMain({ self.host?.mcpInput() ?? .refused("") }) { return true }
        return false
    }

    private func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if running { return false }
        running = true
        return true
    }

    private func release() {
        lock.lock()
        running = false
        lock.unlock()
    }

    private func lastPointer() -> (x: Int, y: Int) {
        lock.lock()
        defer { lock.unlock() }
        return pointer
    }

    private func remember(_ position: (x: Int, y: Int)) {
        lock.lock()
        pointer = position
        lock.unlock()
    }

    // MARK: what the client is told

    private static func report(_ outcome: ActionRunner.Stop, of total: Int,
                               screen: (Int, Int)?) -> String {
        var text: String
        switch outcome {
        case .completed:
            text = total == 0 ? "The VM's screen right now." : "Ran all \(count(total))."
        case .outOfTime(let after):
            text = "Ran \(count(after)) of \(total), then the \(Int(callBudget / 60))-minute limit "
                + "for one call ran out. The screenshot shows where it got to."
        case .failed(let why, let after):
            text = "Ran \(count(after)) of \(total), then stopped: \(why). "
                + "Nothing after that was sent. The screenshot shows where it got to."
        case .interrupted(let after):
            text = "Ran \(count(after)) of \(total), then the VM stopped accepting input."
        }
        if let (width, height) = screen {
            text += " The screen is \(width)x\(height); screenshot pixels are the coordinates to click."
        }
        return text
    }

    private static func note(for outcome: ActionRunner.Stop, of total: Int) -> String {
        switch outcome {
        case .completed: return total == 0 ? "MCP: screenshot" : "MCP: ran \(count(total))"
        case .outOfTime(let after): return "MCP: ran \(count(after)) of \(total), out of time"
        case .failed(_, let after), .interrupted(let after):
            return "MCP: stopped after \(count(after)) of \(total)"
        }
    }

    private static func count(_ n: Int) -> String { "\(n) action\(n == 1 ? "" : "s")" }

    /// The actions array, or nil if it isn't one. A missing list means "just a screenshot".
    private static func actions(_ value: Any?) -> [[String: Any]]? {
        guard let value, !(value is NSNull) else { return [] }
        guard let list = value as? [Any] else { return nil }
        var actions = [[String: Any]]()
        for item in list {
            guard let action = item as? [String: Any] else { return nil }
            actions.append(action)
        }
        return actions
    }

    // MARK: helpers

    private func onMain<T>(_ body: () -> T) -> T {
        Thread.isMainThread ? body() : DispatchQueue.main.sync(execute: body)
    }

    private static func failed(_ message: String) -> [String: Any] {
        ["isError": true, "content": [["type": "text", "text": message]]]
    }

    private static func parse(_ line: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: line) as? [String: Any]
    }

    private func send(_ fd: Int32, _ object: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(0x0a)
        data.withUnsafeBytes { buf in
            var sent = 0
            while sent < buf.count {
                let n = Darwin.send(fd, buf.baseAddress! + sent, buf.count - sent, 0)
                if n <= 0 { return }
                sent += n
            }
        }
    }

    private static func randomHex(_ bytes: Int) -> String {
        (0..<bytes).map { _ in String(format: "%02x", Int.random(in: 0...255)) }.joined()
    }

    struct MCPError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}

/// Newline-delimited reader over a socket or pipe; shared by the server and the stdio bridge.
struct LineReader {
    let fd: Int32
    private var pending = Data()
    private var chunk = [UInt8](repeating: 0, count: 65536)

    init(fd: Int32) { self.fd = fd }

    /// The next line without its newline, or nil at end of stream.
    mutating func next() -> Data? {
        while true {
            if let nl = pending.firstIndex(of: 0x0a) {
                let line = Data(pending[pending.startIndex..<nl])
                pending.removeSubrange(pending.startIndex...nl)
                if !line.isEmpty { return line }
                continue
            }
            let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress!, $0.count) }
            if n <= 0 {
                if n < 0 && errno == EINTR { continue }
                return nil
            }
            pending.append(contentsOf: chunk[0..<n])
        }
    }
}
