import Foundation

/// One RFB event ActionRunner asked for, in the order it asked.
enum VMEvent: Equatable {
    case pointer(x: Int, y: Int, buttons: UInt8)
    case key(UInt32, down: Bool)
}

/// Stands in for RFBClient: records the events instead of writing them to a socket, so a
/// test can assert on exactly what the guest would have received.
final class FakeInput: VMInput {
    var screenSize: (width: Int, height: Int)
    private(set) var events = [VMEvent]()
    private let lock = NSLock()

    init(width: Int = 1280, height: Int = 800) {
        screenSize = (width, height)
    }

    func sendPointer(x: Int, y: Int, buttons: UInt8) {
        lock.lock(); events.append(.pointer(x: x, y: y, buttons: buttons)); lock.unlock()
    }

    func sendKey(_ keysym: UInt32, down: Bool) {
        lock.lock(); events.append(.key(keysym, down: down)); lock.unlock()
    }

    // MARK: reading back what happened

    var pointerEvents: [VMEvent] {
        events.filter { if case .pointer = $0 { return true } else { return false } }
    }

    var keyEvents: [VMEvent] {
        events.filter { if case .key = $0 { return true } else { return false } }
    }

    /// Keysyms pressed down, in order — the shape most key assertions want.
    var keysDown: [UInt32] {
        events.compactMap { if case .key(let sym, true) = $0 { return sym } else { return nil } }
    }

    /// Keysyms released, in order.
    var keysUp: [UInt32] {
        events.compactMap { if case .key(let sym, false) = $0 { return sym } else { return nil } }
    }

    /// The text a `type` action would have produced, reconstructed the way the guest's
    /// keymap would: a keysym pressed while shift is held gives the shifted character.
    var typedText: String {
        var shift = false
        var out = ""
        for event in events {
            guard case .key(let sym, let down) = event else { continue }
            if sym == 0xffe1 || sym == 0xffe2 { shift = down; continue }
            guard down else { continue }
            if sym == 0xff0d { out += "\n"; continue }
            if sym == 0xff09 { out += "\t"; continue }
            guard sym >= 0x20, sym <= 0xff, let scalar = Unicode.Scalar(sym) else { continue }
            let character = Character(scalar)
            out.append(shift ? (Self.shifted[character] ?? character) : character)
        }
        return out
    }

    /// The inverse of ActionRunner's own table, for reading typedText back.
    private static let shifted: [Character: Character] = [
        "`": "~", "1": "!", "2": "@", "3": "#", "4": "$", "5": "%", "6": "^", "7": "&",
        "8": "*", "9": "(", "0": ")", "-": "_", "=": "+", "[": "{", "]": "}", "\\": "|",
        ";": ":", "'": "\"", ",": "<", ".": ">", "/": "?",
    ]

    /// Buttons held after each pointer event, which is how click/drag shape is checked.
    var buttonTrail: [UInt8] {
        events.compactMap { if case .pointer(_, _, let b) = $0 { return b } else { return nil } }
    }

    var positions: [(Int, Int)] {
        events.compactMap { if case .pointer(let x, let y, _) = $0 { return (x, y) } else { return nil } }
    }

    func reset() { lock.lock(); events.removeAll(); lock.unlock() }
}

/// An MCPHost that answers from values a test sets, so MCPServer can be driven over a real
/// socket without a window or a VM.
final class FakeHost: MCPHost {
    /// What mcpInput() returns. Set to nil to refuse with `refusal`.
    var input: VMInput?
    var refusal = "the person has taken control of the VM"
    /// What mcpScreenshotJPEG() returns; nil means no frame yet.
    var screenshot: Data? = Data([0xff, 0xd8, 0xff, 0xd9])
    private(set) var notes = [String]()
    /// Called on every mcpInput(), so a test can take control part-way through a list.
    var onInputQuery: (() -> Void)?
    private let lock = NSLock()

    init(input: VMInput? = nil) { self.input = input }

    func mcpInput() -> MCPInput {
        onInputQuery?()
        lock.lock()
        defer { lock.unlock() }
        if let input { return .ready(input) }
        return .refused(refusal)
    }

    func mcpScreenshotJPEG() -> Data? {
        lock.lock(); defer { lock.unlock() }
        return screenshot
    }

    func mcpNote(_ text: String) {
        lock.lock(); notes.append(text); lock.unlock()
    }

    var noted: [String] { lock.lock(); defer { lock.unlock() }; return notes }
}

// MARK: - test utilities

/// A fresh empty directory for one suite, removed by `cleanup()`.
///
/// The path is kept short on purpose: several suites put Unix sockets in here, and
/// `sockaddr_un.sun_path` holds only 104 bytes — a UUID under the usual temp directory
/// already overruns that, which is why the name is a six-digit suffix and why /tmp is the
/// fallback when TMPDIR is itself too long.
struct TempDir {
    let url: URL

    /// `reserving` is how many bytes the deepest path built inside this directory will add,
    /// so the base can be chosen with room for it.
    init(_ name: String = "nv", reserving longestLeaf: Int = 16) {
        let leaf = "\(name)-\(String(UInt32.random(in: 0...0xff_ffff), radix: 16))"
        let bases = [NSTemporaryDirectory(), "/tmp/"]
        let base = bases.first { candidate in
            let directory = candidate.hasSuffix("/") ? candidate : candidate + "/"
            return (directory + leaf).utf8.count + longestLeaf < 100
        } ?? "/tmp/"
        url = URL(fileURLWithPath: base).appendingPathComponent(leaf, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
    }

    func path(_ name: String) -> String { url.appendingPathComponent(name).path }
    func cleanup() { try? FileManager.default.removeItem(at: url) }
}

/// A Unix socket server on a background thread that hands each connection to `handle`.
/// Used to stand in for QEMU's QMP and VNC servers.
final class FakeSocketServer {
    private let listener: Int32
    let path: String
    private var stopped = false
    private let lock = NSLock()

    init(path: String, handle: @escaping (Int32) -> Void) throws {
        self.path = path
        try? FileManager.default.removeItem(atPath: path)
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw TestError("socket() failed") }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        guard path.utf8.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            throw TestError("socket path too long")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            buf.copyBytes(from: path.utf8)
            buf[path.utf8.count] = 0
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, len) }
        }
        guard rc == 0, listen(listener, 4) == 0 else {
            close(listener)
            throw TestError("bind/listen failed: \(String(cString: strerror(errno)))")
        }
        let thread = Thread { [weak self] in
            while let self, !self.isStopped {
                let conn = accept(self.listener, nil, nil)
                if conn < 0 { return }
                let worker = Thread {
                    handle(conn)
                    close(conn)
                }
                worker.name = "fake socket connection"
                worker.start()
            }
        }
        thread.name = "fake socket server"
        thread.start()
    }

    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

    func stop() {
        lock.lock()
        let already = stopped
        stopped = true
        lock.unlock()
        guard !already else { return }
        close(listener)
        try? FileManager.default.removeItem(atPath: path)
    }
}

struct TestError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: socket read/write helpers for the fake servers

/// write(), not send(), so the same helper works on a pipe and on a socket. The harness
/// ignores SIGPIPE, so writing to a peer that has gone away just returns an error.
func writeAll(_ fd: Int32, _ bytes: [UInt8]) {
    var sent = 0
    bytes.withUnsafeBytes { buf in
        while sent < buf.count {
            let n = Darwin.write(fd, buf.baseAddress! + sent, buf.count - sent)
            if n <= 0 { return }
            sent += n
        }
    }
}

func writeLine(_ fd: Int32, _ object: [String: Any]) {
    guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
    data.append(0x0a)
    writeAll(fd, [UInt8](data))
}

/// Reads exactly `n` bytes, or nil if the peer closed first.
func readExactly(_ fd: Int32, _ n: Int) -> [UInt8]? {
    var buf = [UInt8](repeating: 0, count: n)
    var got = 0
    while got < n {
        let r = buf.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress! + got, n - got) }
        if r <= 0 { return nil }
        got += r
    }
    return buf
}

func bigEndian16(_ v: Int) -> [UInt8] { [UInt8((v >> 8) & 0xff), UInt8(v & 0xff)] }

func bigEndian32(_ v: UInt32) -> [UInt8] {
    [UInt8(v >> 24), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
}

/// Spins until `condition` holds or the timeout passes. Used instead of a fixed sleep so the
/// tests don't depend on how fast a background thread gets going.
@discardableResult
func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        usleep(5_000)
    }
    return condition()
}
