import Foundation

/// Minimal synchronous client for QEMU's QMP control socket (JSON lines over a Unix socket).
/// Blocking: use it off the main thread.
final class QMPClient {
    struct QMPError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    private let fd: Int32
    private var pending = Data()

    /// Connects, reads QEMU's greeting and enables commands. `timeout` bounds each read.
    init(path: String, timeout: TimeInterval = 60) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw QMPError("socket() failed") }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < maxLen else { close(fd); throw QMPError("QMP socket path too long") }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            buf.copyBytes(from: path.utf8)
            buf[path.utf8.count] = 0
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, len) }
        }
        guard rc == 0 else {
            let reason = String(cString: strerror(errno))
            close(fd)
            throw QMPError("QMP connect failed: \(reason)")
        }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        do {
            _ = try readMessage()  // {"QMP": {...}} greeting
            try execute("qmp_capabilities")
        } catch {
            close(fd)
            throw error
        }
    }

    deinit { close(fd) }

    /// Runs a command and returns its "return" object; throws on a QMP error. Events are skipped.
    @discardableResult
    func execute(_ command: String, _ arguments: [String: Any]? = nil) throws -> [String: Any] {
        var message: [String: Any] = ["execute": command]
        if let arguments { message["arguments"] = arguments }
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(0x0a)
        try data.withUnsafeBytes { buf in
            var sent = 0
            while sent < buf.count {
                let r = Darwin.send(fd, buf.baseAddress! + sent, buf.count - sent, 0)
                if r <= 0 { throw QMPError("QMP send failed") }
                sent += r
            }
        }
        while true {
            let reply = try readMessage()
            if let error = reply["error"] as? [String: Any] {
                throw QMPError("\(command): \(error["desc"] as? String ?? "QMP error")")
            }
            if let ret = reply["return"] { return ret as? [String: Any] ?? [:] }
        }
    }

    private func readMessage() throws -> [String: Any] {
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            if let nl = pending.firstIndex(of: 0x0a) {
                let line = pending[pending.startIndex..<nl]
                pending.removeSubrange(pending.startIndex...nl)
                if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { return obj }
                continue
            }
            let n = chunk.withUnsafeMutableBytes { recv(fd, $0.baseAddress!, $0.count, 0) }
            if n <= 0 { throw QMPError(n == 0 ? "QEMU closed the QMP connection" : "QMP read failed or timed out") }
            pending.append(contentsOf: chunk[0..<n])
        }
    }
}
