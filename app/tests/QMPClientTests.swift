import Foundation

/// A stand-in for QEMU's QMP socket. Sends the greeting, then answers each command from
/// `replies` (keyed by command name); a missing key gets `{"return": {}}`.
/// A stand-in for QEMU's QMP socket. Sends the greeting, then answers each command from
/// `replies` (keyed by command name); a missing key gets `{"return": {}}`.
private final class FakeQMP {
    /// Records what the client asked for. A separate object so the socket handler closure
    /// doesn't have to capture a half-initialised FakeQMP.
    final class Box {
        private let lock = NSLock()
        private var commands = [String]()
        private var arguments = [String: [String: Any]]()

        func record(_ command: String, arguments args: [String: Any]?) {
            lock.lock()
            commands.append(command)
            if let args { arguments[command] = args }
            lock.unlock()
        }

        var seen: [String] { lock.lock(); defer { lock.unlock() }; return commands }

        func args(_ command: String) -> [String: Any]? {
            lock.lock(); defer { lock.unlock() }
            return arguments[command]
        }
    }

    let box = Box()
    private let server: FakeSocketServer

    init(path: String,
         replies: [String: [String: Any]] = [:],
         greeting: [String: Any]? = ["QMP": ["version": ["qemu": ["major": 9]]]],
         events: Int = 0,
         closeAfter: Int? = nil) throws {
        let box = self.box
        server = try FakeSocketServer(path: path) { fd in
            if let greeting { writeLine(fd, greeting) }
            var reader = LineReader(fd: fd)
            var handled = 0
            while let line = reader.next() {
                guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let command = message["execute"] as? String else { continue }
                box.record(command, arguments: message["arguments"] as? [String: Any])
                // closeAfter lets a test see what happens when QEMU goes away mid-command
                if let closeAfter, handled >= closeAfter { return }
                handled += 1
                // QMP events may arrive at any time and the client has to skip them
                for _ in 0..<events {
                    writeLine(fd, ["event": "STOP", "timestamp": ["seconds": 1, "microseconds": 0]])
                }
                writeLine(fd, replies[command] ?? ["return": [:] as [String: Any]])
            }
        }
    }

    func stop() { server.stop() }
}

func qmpClientTests(_ t: TestRunner) {
    let dir = TempDir("qmp")
    defer { dir.cleanup() }

    t.suite("QMPClient: connects, reads the greeting and enables commands") {
        let path = dir.path("ok.sock")
        let fake = try FakeQMP(path: path)
        defer { fake.stop() }
        let client = try QMPClient(path: path, timeout: 5)
        // qmp_capabilities has to be sent before anything else works
        t.expect(waitUntil { fake.box.seen.contains("qmp_capabilities") },
                 "the client should negotiate capabilities on connect")
        let result = try client.execute("query-status")
        t.equal(result.isEmpty, true, "an empty return object comes back as [:]")
        t.equal(fake.box.seen, ["qmp_capabilities", "query-status"], "in that order")
    }

    t.suite("QMPClient: returns the command's return object") {
        let path = dir.path("ret.sock")
        let fake = try FakeQMP(path: path, replies: [
            "query-status": ["return": ["status": "running", "running": true]],
        ])
        defer { fake.stop() }
        let client = try QMPClient(path: path, timeout: 5)
        let result = try client.execute("query-status")
        t.equal(result["status"] as? String, "running", "the status should come back")
        t.equal(result["running"] as? Bool, true, "and the rest of the object with it")
    }

    t.suite("QMPClient: passes arguments through") {
        let path = dir.path("args.sock")
        let fake = try FakeQMP(path: path)
        defer { fake.stop() }
        let client = try QMPClient(path: path, timeout: 5)
        try client.execute("migrate", ["uri": "file:/tmp/vmstate"])
        t.equal(fake.box.args("migrate")?["uri"] as? String, "file:/tmp/vmstate",
                "the arguments should reach QEMU")
    }

    t.suite("QMPClient: a QMP error becomes a thrown error with its description") {
        let path = dir.path("err.sock")
        let fake = try FakeQMP(path: path, replies: [
            "migrate": ["error": ["class": "GenericError", "desc": "migration is disabled"]],
        ])
        defer { fake.stop() }
        let client = try QMPClient(path: path, timeout: 5)
        do {
            try client.execute("migrate", ["uri": "file:/nowhere"])
            t.expect(false, "a QMP error should throw")
        } catch {
            t.equal(error.localizedDescription, "migrate: migration is disabled",
                    "the command and QEMU's description should both be in the message")
        }
    }

    t.suite("QMPClient: an error with no description still throws") {
        let path = dir.path("err2.sock")
        let fake = try FakeQMP(path: path, replies: ["stop": ["error": [:] as [String: Any]]])
        defer { fake.stop() }
        let client = try QMPClient(path: path, timeout: 5)
        do {
            try client.execute("stop")
            t.expect(false, "it should still throw")
        } catch {
            t.equal(error.localizedDescription, "stop: QMP error", "with a fallback description")
        }
    }

    t.suite("QMPClient: events between commands are skipped") {
        // QEMU emits events asynchronously; they are not the reply being waited for.
        let path = dir.path("events.sock")
        let fake = try FakeQMP(path: path, replies: [
            "query-status": ["return": ["status": "paused"]],
        ], events: 3)
        defer { fake.stop() }
        let client = try QMPClient(path: path, timeout: 5)
        let result = try client.execute("query-status")
        t.equal(result["status"] as? String, "paused", "the reply should be found past the events")
    }

    t.suite("QMPClient: non-JSON lines are skipped") {
        let path = dir.path("junk.sock")
        let server = try FakeSocketServer(path: path) { fd in
            writeAll(fd, [UInt8]("not json at all\n".utf8))
            writeLine(fd, ["QMP": [:] as [String: Any]])
            var reader = LineReader(fd: fd)
            while let line = reader.next() {
                guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      message["execute"] != nil else { continue }
                writeAll(fd, [UInt8]("}{ broken\n".utf8))
                writeLine(fd, ["return": [:] as [String: Any]])
            }
        }
        defer { server.stop() }
        let client = try QMPClient(path: path, timeout: 5)
        let result = try client.execute("query-status")
        t.equal(result.isEmpty, true, "the client should get past the junk to the reply")
    }

    t.suite("QMPClient: refuses a socket path that won't fit in sockaddr_un") {
        let long = "/tmp/" + String(repeating: "a", count: 200) + ".sock"
        do {
            _ = try QMPClient(path: long, timeout: 1)
            t.expect(false, "an over-long path should throw")
        } catch {
            t.equal(error.localizedDescription, "QMP socket path too long",
                    "and say which limit was hit")
        }
    }

    t.suite("QMPClient: a missing socket fails to connect") {
        do {
            _ = try QMPClient(path: dir.path("not-there.sock"), timeout: 1)
            t.expect(false, "connecting to nothing should throw")
        } catch {
            t.expect(error.localizedDescription.hasPrefix("QMP connect failed:"),
                     "with a connect failure, got: \(error.localizedDescription)")
        }
    }

    t.suite("QMPClient: a server that closes during the handshake throws") {
        let path = dir.path("rude.sock")
        let server = try FakeSocketServer(path: path) { _ in }  // closes immediately
        defer { server.stop() }
        do {
            _ = try QMPClient(path: path, timeout: 2)
            t.expect(false, "a closed connection should throw")
        } catch {
            t.equal(error.localizedDescription, "QEMU closed the QMP connection",
                    "and say the connection went away")
        }
    }

    t.suite("QMPClient: a server that closes mid-command throws") {
        let path = dir.path("halfway.sock")
        let fake = try FakeQMP(path: path, closeAfter: 1)
        defer { fake.stop() }
        let client = try QMPClient(path: path, timeout: 2)
        do {
            try client.execute("query-status")
            t.expect(false, "the command should fail once QEMU goes away")
        } catch {
            t.expect(error.localizedDescription.contains("QMP"),
                     "with a QMP error, got: \(error.localizedDescription)")
        }
    }
}
