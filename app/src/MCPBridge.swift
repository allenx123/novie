import Foundation

/// `NovieMCP --mcp`: an MCP server on stdio that hands every tool call to the running
/// Novie window over its Unix socket (see MCPServer), so another agent can work the VM's
/// mouse and keyboard the way the person at the window does.
///
/// It is the same binary as the app so there is nothing extra to install:
///   claude mcp add novie -- /Applications/Novie.app/Contents/MacOS/NovieMCP --mcp
///
/// The protocol handshake is answered here, so the server still starts (and can explain
/// itself) when Novie isn't running; only tool calls need the app.
enum MCPBridge {
    static let name = "novie"
    static let version = "0.2.0"
    /// Protocol revisions this server is known to work with; anything else gets our newest.
    static let protocolVersions = ["2024-11-05", "2025-03-26", "2025-06-18"]

    /// The one tool: a list of mouse, keyboard and wait actions, then a screenshot.
    private static let tools: [[String: Any]] = [
        tool("computer",
             """
             Work the mouse and keyboard of the Linux desktop running in Novie's VM. Takes a \
             list of actions, plays them into the VM in order, and always comes back with a \
             screenshot of the screen afterwards — so pass an empty list to just look at the \
             screen. Coordinates are pixels in that screenshot, with [0, 0] at the top left. \
             The screenshot is taken the moment the actions finish, so after anything that \
             opens a window, loads a page or starts a program, end the list with a \
             {"action": "wait"} and look at the screenshot before deciding what to click next. \
             One call may spend up to 10 minutes playing its actions. The person at the Mac \
             can take the VM's mouse and keyboard at any time, and while they hold them this \
             tool does nothing and returns no screenshot.
             """,
             ["actions": [
                 "type": "array",
                 "description": "The actions to play, in order. Empty for just a screenshot.",
                 "items": [
                     "type": "object",
                     "properties": [
                         "action": [
                             "type": "string",
                             "enum": ["key", "type", "mouse_move", "left_click", "right_click",
                                      "middle_click", "double_click", "triple_click",
                                      "left_click_drag", "left_mouse_down", "left_mouse_up",
                                      "scroll", "hold_key", "wait", "screenshot"],
                             "description": """
                                 key: press a key or combo from text ("Return", "ctrl+s", "alt+Tab"). \
                                 type: type the text in text (ASCII; a newline presses Return). \
                                 mouse_move: move the pointer to coordinate. \
                                 left_click / right_click / middle_click / double_click / triple_click: \
                                 click at coordinate, or where the pointer already is. \
                                 left_click_drag: press at start_coordinate and release at coordinate. \
                                 left_mouse_down / left_mouse_up: hold and let go of the left button \
                                 (anything still held is released when the list ends). \
                                 scroll: turn the wheel at coordinate, scroll_amount clicks in \
                                 scroll_direction. hold_key: hold text down for duration seconds. \
                                 wait: do nothing for duration seconds, to let the guest catch up. \
                                 screenshot: nothing, since a screenshot always comes back.
                                 """,
                         ],
                         "coordinate": [
                             "type": "array", "items": ["type": "integer"],
                             "minItems": 2, "maxItems": 2,
                             "description": "[x, y] in screenshot pixels: where to click, move, scroll or drag to.",
                         ],
                         "start_coordinate": [
                             "type": "array", "items": ["type": "integer"],
                             "minItems": 2, "maxItems": 2,
                             "description": "[x, y] a left_click_drag starts from.",
                         ],
                         "text": [
                             "type": "string",
                             "description": """
                                 For key and hold_key, the key or combo ("Return", "Tab", "Escape", \
                                 "BackSpace", "Delete", "Up", "Page_Down", "F5", "ctrl+shift+t"). \
                                 For type, the text to type. For a click or scroll, modifier keys to \
                                 hold while it happens ("ctrl", "shift").
                                 """,
                         ],
                         "duration": [
                             "type": "number",
                             "description": "Seconds, for wait (default 1) and hold_key.",
                         ],
                         "scroll_direction": [
                             "type": "string", "enum": ["up", "down"],
                             "description": "Which way to turn the wheel. For sideways scrolling, hold shift with text.",
                         ],
                         "scroll_amount": [
                             "type": "integer",
                             "description": "Wheel clicks to turn (default 3).",
                         ],
                     ],
                     "required": ["action"],
                 ],
             ]],
             required: ["actions"]),
    ]

    private static func tool(_ name: String, _ description: String,
                             _ properties: [String: Any], required: [String] = []) -> [String: Any] {
        var schema: [String: Any] = ["type": "object", "properties": properties]
        if !required.isEmpty { schema["required"] = required }
        return ["name": name,
                "description": description.replacingOccurrences(of: "\n", with: ""),
                "inputSchema": schema]
    }

    static func run() -> Never {
        signal(SIGPIPE, SIG_IGN)
        var app = AppConnection()
        var input = LineReader(fd: 0)
        while let line = input.next() {
            guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                reply(["jsonrpc": "2.0", "id": NSNull(),
                       "error": ["code": -32700, "message": "invalid JSON"]])
                continue
            }
            let id = message["id"]
            guard let method = message["method"] as? String else { continue }
            guard let id, !(id is NSNull) else { continue }  // a notification wants no answer

            switch method {
            case "initialize":
                let asked = (message["params"] as? [String: Any])?["protocolVersion"] as? String
                let client = ((message["params"] as? [String: Any])?["clientInfo"] as? [String: Any])?["name"] as? String
                app.clientName = client ?? "an agent"
                reply(result: [
                    "protocolVersion": protocolVersions.contains(asked ?? "") ? asked! : protocolVersions.last!,
                    "capabilities": ["tools": [:] as [String: Any]],
                    "serverInfo": ["name": name, "version": version],
                    "instructions": """
                        Novie shows a Linux desktop running in a VM on this Mac. The computer \
                        tool works its mouse and keyboard and hands back a screenshot, so drive \
                        it in a loop: look at the screen, send a few actions, look again, and \
                        give the desktop time to redraw before judging what is on it. The person \
                        at the Mac is watching the same window and can take the mouse and \
                        keyboard away at any time.
                        """,
                ], id: id)
            case "ping":
                reply(result: [:], id: id)
            case "tools/list":
                reply(result: ["tools": tools], id: id)
            case "tools/call":
                let params = message["params"] as? [String: Any] ?? [:]
                let tool = params["name"] as? String ?? ""
                let arguments = params["arguments"] as? [String: Any] ?? [:]
                reply(result: app.call(tool, arguments), id: id)
            default:
                reply(["jsonrpc": "2.0", "id": id,
                       "error": ["code": -32601, "message": "unknown method: \(method)"]])
            }
        }
        exit(0)
    }

    // MARK: the running app

    /// The connection to Novie's socket, opened on the first tool call and reopened if the
    /// app is restarted. Tool calls fail with an explanation while it isn't running.
    private struct AppConnection {
        var clientName = "an agent"
        private var fd: Int32 = -1
        private var reader: LineReader?
        private var nextID = 1

        private var runDir: URL {
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Novie", isDirectory: true)
        }

        mutating func call(_ tool: String, _ arguments: [String: Any]) -> [String: Any] {
            // Retry only while nothing has been sent: once the actions are on their way, a
            // second attempt could click everything twice.
            for attempt in 0..<2 {
                if fd < 0, let failure = connect() {
                    return MCPBridge.failed(failure)
                }
                let id = nextID
                nextID += 1
                guard send(["id": id, "call": tool, "args": arguments]) else {
                    disconnect()
                    if attempt == 0 { continue }  // the app went away before the call; try once more
                    break
                }
                guard let line = reader?.next(),
                      let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    disconnect()
                    return MCPBridge.failed("""
                        Novie stopped answering part-way through this call, so some of the actions \
                        may have run. Make sure the app is still open, then take a screenshot \
                        (an empty action list) to see where the VM got to.
                        """)
                }
                return ["content": object["content"] ?? [], "isError": object["isError"] as? Bool ?? false]
            }
            return MCPBridge.failed("Lost the connection to Novie. Make sure the app is still open.")
        }

        private mutating func connect() -> String? {
            let path = MCPServer.socketPath(in: runDir)
            guard let token = try? String(contentsOfFile: MCPServer.tokenPath(in: runDir), encoding: .utf8),
                  FileManager.default.fileExists(atPath: path) else {
                return "Novie isn't running. Open Novie.app, wait for the VM's screen to appear, and try again."
            }
            let sock = socket(AF_UNIX, SOCK_STREAM, 0)
            guard sock >= 0 else { return "socket() failed" }
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            guard path.utf8.count < MemoryLayout.size(ofValue: addr.sun_path) else {
                close(sock)
                return "the MCP socket path is too long"
            }
            withUnsafeMutableBytes(of: &addr.sun_path) { buf in
                buf.copyBytes(from: path.utf8)
                buf[path.utf8.count] = 0
            }
            let len = socklen_t(MemoryLayout<sockaddr_un>.size)
            let rc = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(sock, $0, len) }
            }
            guard rc == 0 else {
                close(sock)
                return "Novie isn't running. Open Novie.app, wait for the VM's screen to appear, and try again."
            }
            var on: Int32 = 1
            setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            fd = sock
            reader = LineReader(fd: sock)
            guard send(["hello": token.trimmingCharacters(in: .whitespacesAndNewlines), "client": clientName]),
                  let line = reader?.next(),
                  let answer = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                disconnect()
                return "Novie closed the connection without answering."
            }
            if let refusal = answer["error"] as? String {
                disconnect()
                return refusal
            }
            return nil
        }

        private mutating func disconnect() {
            if fd >= 0 { close(fd) }
            fd = -1
            reader = nil
        }

        private func send(_ object: [String: Any]) -> Bool {
            guard fd >= 0, var data = try? JSONSerialization.data(withJSONObject: object) else { return false }
            data.append(0x0a)
            return data.withUnsafeBytes { buf in
                var sent = 0
                while sent < buf.count {
                    let n = Darwin.send(fd, buf.baseAddress! + sent, buf.count - sent, 0)
                    if n <= 0 { return false }
                    sent += n
                }
                return true
            }
        }
    }

    // MARK: stdio

    private static func failed(_ message: String) -> [String: Any] {
        ["isError": true, "content": [["type": "text", "text": message]]]
    }

    private static func reply(result: [String: Any], id: Any) {
        reply(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private static func reply(_ message: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: message) else { return }
        data.append(0x0a)
        data.withUnsafeBytes { buf in
            var sent = 0
            while sent < buf.count {
                let n = write(1, buf.baseAddress! + sent, buf.count - sent)
                if n <= 0 { return }
                sent += n
            }
        }
    }
}
