import CoreGraphics
import Foundation

/// A stand-in for QEMU's VNC server: does the RFB 3.8 handshake the way RFBClient expects,
/// consumes the first FramebufferUpdateRequest, then hands the connection to the test so it
/// can push updates and read back the input messages the client sends.
private final class FakeRFB {
    /// Shared with the socket handler, so the closure never captures a half-built FakeRFB.
    final class Box {
        let handshakeDone = DispatchSemaphore(value: 0)
        /// Signalled by stop(); until then the handler keeps the connection open so the
        /// test can push updates into it and read the client's input messages back.
        let keepOpen = DispatchSemaphore(value: 0)
        private var fd: Int32 = -1
        private let lock = NSLock()

        func ready(_ connection: Int32) {
            lock.lock(); fd = connection; lock.unlock()
            handshakeDone.signal()
        }

        var connection: Int32 { lock.lock(); defer { lock.unlock() }; return fd }
    }

    private let box = Box()
    private let server: FakeSocketServer

    /// Each knob here is a handshake step a test can make go wrong.
    init(path: String,
         width: Int = 1280, height: Int = 800,
         version: String = "RFB 003.008\n",
         securityTypes: [UInt8]? = [1],
         securityFailure: String? = nil,
         name: String = "QEMU") throws {
        // RFBClient reads a fixed 12 bytes, so a shorter greeting would leave it blocked
        // in recv() rather than failing the test.
        guard version.utf8.count == 12 else {
            throw TestError("an RFB greeting must be exactly 12 bytes, got \(version.utf8.count)")
        }
        let box = self.box
        server = try FakeSocketServer(path: path) { fd in
            writeAll(fd, [UInt8](version.utf8))
            guard readExactly(fd, 12) != nil else { return }  // the client's version

            guard let securityTypes else {
                // A count of zero means the server is refusing, with a reason
                let reason = securityFailure ?? "no security types"
                writeAll(fd, [0] + bigEndian32(UInt32(reason.utf8.count)) + [UInt8](reason.utf8))
                return
            }
            writeAll(fd, [UInt8(securityTypes.count)] + securityTypes)
            guard readExactly(fd, 1) != nil else { return }  // the type the client chose
            if let securityFailure {
                writeAll(fd, bigEndian32(1) + bigEndian32(UInt32(securityFailure.utf8.count))
                         + [UInt8](securityFailure.utf8))
                return
            }
            writeAll(fd, bigEndian32(0))  // security result: OK

            guard readExactly(fd, 1) != nil else { return }  // ClientInit
            var serverInit = bigEndian16(width) + bigEndian16(height)
            serverInit += [32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0]
            serverInit += bigEndian32(UInt32(name.utf8.count)) + [UInt8](name.utf8)
            writeAll(fd, serverInit)

            // SetPixelFormat (20) + SetEncodings (4 + 3 encodings), then the first request (10)
            guard readExactly(fd, 20 + 16) != nil, readExactly(fd, 10) != nil else { return }
            box.ready(fd)
            box.keepOpen.wait()
        }
    }

    /// Waits for the handshake to finish and returns the connection; nil if it never did.
    func waitForHandshake(timeout: TimeInterval = 5) -> Int32? {
        guard box.handshakeDone.wait(timeout: .now() + timeout) == .success else { return nil }
        return box.connection
    }

    /// Sends one FramebufferUpdate with the given rectangles.
    func sendUpdate(_ fd: Int32,
                    rects: [(x: Int, y: Int, w: Int, h: Int, encoding: Int32, data: [UInt8])]) {
        var message: [UInt8] = [0, 0] + bigEndian16(rects.count)
        for rect in rects {
            message += bigEndian16(rect.x) + bigEndian16(rect.y)
            message += bigEndian16(rect.w) + bigEndian16(rect.h)
            message += bigEndian32(UInt32(bitPattern: rect.encoding))
            message += rect.data
        }
        writeAll(fd, message)
    }

    /// Consumes the FramebufferUpdateRequest the client sends after each update.
    func consumeUpdateRequest(_ fd: Int32) { _ = readExactly(fd, 10) }

    func stop() {
        box.keepOpen.signal()
        server.stop()
    }
}

/// The raw BGRX bytes behind a snapshot, so a test can check what was painted.
private func pixels(of image: CGImage) -> [UInt8] {
    guard let data = image.dataProvider?.data else { return [] }
    return [UInt8](Data(referencing: data))
}

/// Four bytes for one pixel, in the BGRX order QEMU is asked for.
private func bgrx(_ b: UInt8, _ g: UInt8, _ r: UInt8) -> [UInt8] { [b, g, r, 0] }

func rfbClientTests(_ t: TestRunner) {
    let dir = TempDir("rfb")
    defer { dir.cleanup() }

    t.suite("RFBClient: completes the handshake and learns the screen size") {
        let path = dir.path("ok.sock")
        let fake = try FakeRFB(path: path, width: 1280, height: 800)
        defer { fake.stop() }
        let client = RFBClient()
        var resized = [(Int, Int)]()
        let lock = NSLock()
        client.onResize = { w, h in lock.lock(); resized.append((w, h)); lock.unlock() }
        try client.connect(path: path)
        t.expect(fake.waitForHandshake() != nil, "the handshake should finish")
        t.equal(client.width, 1280, "width should come from ServerInit")
        t.equal(client.height, 800, "height should come from ServerInit")
        t.expect(waitUntil { lock.lock(); defer { lock.unlock() }; return resized.count == 1 },
                 "onResize should fire once for the initial size")
        t.equal(resized.first.map { [$0.0, $0.1] } ?? [], [1280, 800], "with the screen size")
        // The VMInput conformance is what ActionRunner checks coordinates against
        t.equal(client.screenSize.width, 1280, "screenSize should follow the framebuffer")
        t.equal(client.screenSize.height, 800, "both dimensions")
        client.disconnect()
    }

    t.suite("RFBClient: snapshot is nil until there is a framebuffer") {
        let client = RFBClient()
        t.expect(client.snapshot() == nil, "with no connection there is nothing to snapshot")
        t.equal(client.width, 0, "and no width")
    }

    t.suite("RFBClient: a Raw rectangle is painted into the framebuffer") {
        let path = dir.path("raw.sock")
        let fake = try FakeRFB(path: path, width: 2, height: 2)
        defer { fake.stop() }
        let client = RFBClient()
        let frames = FrameCounter()
        client.onFrame = { _ = frames.next() }
        try client.connect(path: path)
        guard let fd = fake.waitForHandshake() else {
            t.expect(false, "handshake should finish"); return
        }
        // Four distinct pixels across the whole 2x2 screen
        let data = bgrx(1, 2, 3) + bgrx(4, 5, 6) + bgrx(7, 8, 9) + bgrx(10, 11, 12)
        fake.sendUpdate(fd, rects: [(x: 0, y: 0, w: 2, h: 2, encoding: 0, data: data)])
        t.expect(waitUntil { frames.peek() >= 1 }, "onFrame should fire for the update")
        guard let image = client.snapshot() else {
            t.expect(false, "there should be a snapshot now"); return
        }
        t.equal(image.width, 2, "the image should be the screen width")
        t.equal(image.height, 2, "and height")
        t.equal(image.bitsPerPixel, 32, "32 bits per pixel")
        t.equal(pixels(of: image), data, "the pixels should be exactly what the server sent")
        fake.consumeUpdateRequest(fd)
        client.disconnect()
    }

    t.suite("RFBClient: a partial Raw rectangle lands at its offset") {
        let path = dir.path("partial.sock")
        let fake = try FakeRFB(path: path, width: 2, height: 2)
        defer { fake.stop() }
        let client = RFBClient()
        let frames = FrameCounter()
        client.onFrame = { _ = frames.next() }
        try client.connect(path: path)
        guard let fd = fake.waitForHandshake() else {
            t.expect(false, "handshake should finish"); return
        }
        // One pixel at the bottom right only; everything else stays black
        fake.sendUpdate(fd, rects: [(x: 1, y: 1, w: 1, h: 1, encoding: 0, data: bgrx(9, 9, 9))])
        t.expect(waitUntil { frames.peek() >= 1 }, "the update should arrive")
        let painted = pixels(of: client.snapshot()!)
        t.equal(Array(painted[0..<12]), [UInt8](repeating: 0, count: 12),
                "the other three pixels should still be black")
        t.equal(Array(painted[12..<16]), bgrx(9, 9, 9), "the painted pixel should be at [1,1]")
        fake.consumeUpdateRequest(fd)
        client.disconnect()
    }

    t.suite("RFBClient: a Raw rectangle that runs off the screen is clipped") {
        // QEMU shouldn't send one, but a rect wider or taller than the framebuffer must not
        // be allowed to write past the end of it.
        let path = dir.path("clip.sock")
        let fake = try FakeRFB(path: path, width: 2, height: 2)
        defer { fake.stop() }
        let client = RFBClient()
        let frames = FrameCounter()
        client.onFrame = { _ = frames.next() }
        try client.connect(path: path)
        guard let fd = fake.waitForHandshake() else {
            t.expect(false, "handshake should finish"); return
        }
        // 2x2 rect starting at [1,1]: only its top-left pixel is on screen
        let data = bgrx(1, 1, 1) + bgrx(2, 2, 2) + bgrx(3, 3, 3) + bgrx(4, 4, 4)
        fake.sendUpdate(fd, rects: [(x: 1, y: 1, w: 2, h: 2, encoding: 0, data: data)])
        t.expect(waitUntil { frames.peek() >= 1 }, "the update should arrive")
        let painted = pixels(of: client.snapshot()!)
        t.equal(painted.count, 16, "the framebuffer should still be 2x2")
        t.equal(Array(painted[12..<16]), bgrx(1, 1, 1), "only the on-screen pixel is written")
        fake.consumeUpdateRequest(fd)
        client.disconnect()
    }

    t.suite("RFBClient: CopyRect moves pixels within the framebuffer") {
        let path = dir.path("copy.sock")
        let fake = try FakeRFB(path: path, width: 2, height: 2)
        defer { fake.stop() }
        let client = RFBClient()
        let frames = FrameCounter()
        client.onFrame = { _ = frames.next() }
        try client.connect(path: path)
        guard let fd = fake.waitForHandshake() else {
            t.expect(false, "handshake should finish"); return
        }
        let top = bgrx(1, 2, 3) + bgrx(4, 5, 6)
        let bottom = bgrx(7, 8, 9) + bgrx(10, 11, 12)
        fake.sendUpdate(fd, rects: [(x: 0, y: 0, w: 2, h: 2, encoding: 0, data: top + bottom)])
        t.expect(waitUntil { frames.peek() >= 1 }, "the raw fill should arrive")
        fake.consumeUpdateRequest(fd)

        // Copy the top row down over the bottom one
        fake.sendUpdate(fd, rects: [(x: 0, y: 1, w: 2, h: 1, encoding: 1,
                                     data: bigEndian16(0) + bigEndian16(0))])
        t.expect(waitUntil { frames.peek() >= 2 }, "the CopyRect should arrive")
        let painted = pixels(of: client.snapshot()!)
        t.equal(Array(painted[0..<8]), top, "the top row should be unchanged")
        t.equal(Array(painted[8..<16]), top, "the bottom row should now be a copy of the top")
        fake.consumeUpdateRequest(fd)
        client.disconnect()
    }

    t.suite("RFBClient: DesktopSize re-sizes the framebuffer") {
        // A guest that changes resolution takes the window with it through onResize.
        let path = dir.path("resize.sock")
        let fake = try FakeRFB(path: path, width: 2, height: 2)
        defer { fake.stop() }
        let client = RFBClient()
        let frames = FrameCounter()
        var sizes = [(Int, Int)]()
        let lock = NSLock()
        client.onFrame = { _ = frames.next() }
        client.onResize = { w, h in lock.lock(); sizes.append((w, h)); lock.unlock() }
        try client.connect(path: path)
        guard let fd = fake.waitForHandshake() else {
            t.expect(false, "handshake should finish"); return
        }
        fake.sendUpdate(fd, rects: [(x: 0, y: 0, w: 640, h: 480, encoding: -223, data: [])])
        t.expect(waitUntil { client.width == 640 }, "the client should take the new width")
        t.equal(client.height, 480, "and the new height")
        t.expect(waitUntil { lock.lock(); defer { lock.unlock() }; return sizes.count == 2 },
                 "onResize should fire again")
        t.equal(sizes.last.map { [$0.0, $0.1] } ?? [], [640, 480], "with the new size")
        guard let image = client.snapshot() else {
            t.expect(false, "the resized framebuffer should still snapshot"); return
        }
        t.equal(image.width, 640, "the snapshot should be the new size")
        fake.consumeUpdateRequest(fd)
        client.disconnect()
    }

    t.suite("RFBClient: Bell, colour map and cut text are ignored") {
        // None of these mean anything here, but mishandling one would desynchronise the
        // stream and take the display down.
        let path = dir.path("chatter.sock")
        let fake = try FakeRFB(path: path, width: 2, height: 2)
        defer { fake.stop() }
        let client = RFBClient()
        let frames = FrameCounter()
        var disconnects = [String]()
        let lock = NSLock()
        client.onFrame = { _ = frames.next() }
        client.onDisconnect = { why in lock.lock(); disconnects.append(why); lock.unlock() }
        try client.connect(path: path)
        guard let fd = fake.waitForHandshake() else {
            t.expect(false, "handshake should finish"); return
        }
        writeAll(fd, [2])                                               // Bell
        writeAll(fd, [1, 0] + bigEndian16(0) + bigEndian16(2)
                 + [UInt8](repeating: 7, count: 12))                     // SetColourMapEntries
        writeAll(fd, [3, 0, 0, 0] + bigEndian32(5) + [UInt8]("hello".utf8))  // ServerCutText
        // A real update after the chatter proves the stream is still aligned
        fake.sendUpdate(fd, rects: [(x: 0, y: 0, w: 1, h: 1, encoding: 0, data: bgrx(5, 5, 5))])
        t.expect(waitUntil { frames.peek() >= 1 }, "the update after the chatter should arrive")
        t.equal(Array(pixels(of: client.snapshot()!)[0..<4]), bgrx(5, 5, 5),
                "and be painted correctly")
        lock.lock()
        t.equal(disconnects.count, 0, "nothing should have disconnected")
        lock.unlock()
        fake.consumeUpdateRequest(fd)
        client.disconnect()
    }

    t.suite("RFBClient: an unexpected message disconnects with a reason") {
        let path = dir.path("bogus.sock")
        let fake = try FakeRFB(path: path, width: 2, height: 2)
        defer { fake.stop() }
        let client = RFBClient()
        var reason: String?
        let lock = NSLock()
        client.onDisconnect = { why in lock.lock(); reason = why; lock.unlock() }
        try client.connect(path: path)
        guard let fd = fake.waitForHandshake() else {
            t.expect(false, "handshake should finish"); return
        }
        writeAll(fd, [99])
        t.expect(waitUntil { lock.lock(); defer { lock.unlock() }; return reason != nil },
                 "the client should report the disconnect")
        lock.lock()
        t.equal(reason, "unexpected message 99", "naming the message it couldn't handle")
        lock.unlock()
    }

    t.suite("RFBClient: an unsupported encoding disconnects with a reason") {
        let path = dir.path("encoding.sock")
        let fake = try FakeRFB(path: path, width: 2, height: 2)
        defer { fake.stop() }
        let client = RFBClient()
        var reason: String?
        let lock = NSLock()
        client.onDisconnect = { why in lock.lock(); reason = why; lock.unlock() }
        try client.connect(path: path)
        guard let fd = fake.waitForHandshake() else {
            t.expect(false, "handshake should finish"); return
        }
        fake.sendUpdate(fd, rects: [(x: 0, y: 0, w: 1, h: 1, encoding: 5, data: [])])  // Hextile
        t.expect(waitUntil { lock.lock(); defer { lock.unlock() }; return reason != nil },
                 "an encoding we didn't ask for should be reported")
        lock.lock()
        t.equal(reason, "unsupported encoding 5", "naming the encoding")
        lock.unlock()
    }

    t.suite("RFBClient: a deliberate disconnect is silent") {
        // Closing the window shouldn't look like the VM going away.
        let path = dir.path("quiet.sock")
        let fake = try FakeRFB(path: path, width: 2, height: 2)
        defer { fake.stop() }
        let client = RFBClient()
        var disconnects = 0
        let lock = NSLock()
        client.onDisconnect = { _ in lock.lock(); disconnects += 1; lock.unlock() }
        try client.connect(path: path)
        t.expect(fake.waitForHandshake() != nil, "handshake should finish")
        client.disconnect()
        usleep(200_000)
        lock.lock()
        t.equal(disconnects, 0, "onDisconnect should not fire for our own disconnect")
        lock.unlock()
    }

    // MARK: input messages on the wire

    t.suite("RFBClient: pointer events are encoded as RFB PointerEvent") {
        let path = dir.path("pointer.sock")
        let fake = try FakeRFB(path: path, width: 1280, height: 800)
        defer { fake.stop() }
        let client = RFBClient()
        try client.connect(path: path)
        guard let fd = fake.waitForHandshake() else {
            t.expect(false, "handshake should finish"); return
        }
        client.sendPointer(x: 0x0102, y: 0x0304, buttons: 5)
        t.equal(readExactly(fd, 6) ?? [], [5, 5, 0x01, 0x02, 0x03, 0x04],
                "message type 5, the button mask, then x and y big-endian")
        client.disconnect()
    }

    t.suite("RFBClient: pointer coordinates are clamped to the screen") {
        // Nothing should be able to send the guest a position that isn't on its screen.
        let path = dir.path("clamp.sock")
        let fake = try FakeRFB(path: path, width: 100, height: 50)
        defer { fake.stop() }
        let client = RFBClient()
        try client.connect(path: path)
        guard let fd = fake.waitForHandshake() else {
            t.expect(false, "handshake should finish"); return
        }
        client.sendPointer(x: 9999, y: 9999, buttons: 0)
        t.equal(readExactly(fd, 6) ?? [], [5, 0, 0, 99, 0, 49], "too far right and down clamps to 99,49")
        client.sendPointer(x: -5, y: -5, buttons: 0)
        t.equal(readExactly(fd, 6) ?? [], [5, 0, 0, 0, 0, 0], "negative clamps to 0,0")
        client.disconnect()
    }

    t.suite("RFBClient: key events are encoded as RFB KeyEvent") {
        let path = dir.path("key.sock")
        let fake = try FakeRFB(path: path, width: 2, height: 2)
        defer { fake.stop() }
        let client = RFBClient()
        try client.connect(path: path)
        guard let fd = fake.waitForHandshake() else {
            t.expect(false, "handshake should finish"); return
        }
        client.sendKey(0xff0d, down: true)
        t.equal(readExactly(fd, 8) ?? [], [4, 1, 0, 0, 0, 0, 0xff, 0x0d],
                "type 4, down flag, two pad bytes, then the keysym big-endian")
        client.sendKey(0xff0d, down: false)
        t.equal(readExactly(fd, 8) ?? [], [4, 0, 0, 0, 0, 0, 0xff, 0x0d], "and the key-up")
        client.disconnect()
    }

    t.suite("RFBClient: input before a connection is dropped, not crashed on") {
        let client = RFBClient()
        client.sendPointer(x: 1, y: 1, buttons: 1)
        client.sendKey(0x61, down: true)
        t.expect(true, "sending with no socket should be a no-op")
    }

    // MARK: handshake failures

    t.suite("RFBClient: a server that isn't VNC is refused") {
        let path = dir.path("http.sock")
        let fake = try FakeRFB(path: path, version: "HTTP/1.1 200")  // 12 bytes, like a real greeting
        defer { fake.stop() }
        do {
            try RFBClient().connect(path: path)
            t.expect(false, "a non-VNC greeting should throw")
        } catch {
            t.equal((error as? RFBError)?.message, "not a VNC server", "saying what it isn't")
        }
    }

    t.suite("RFBClient: a server demanding authentication is refused") {
        // QEMU is configured without auth; if it ever asks, we can't answer.
        let path = dir.path("auth.sock")
        let fake = try FakeRFB(path: path, securityTypes: [2])  // VNC auth only
        defer { fake.stop() }
        do {
            try RFBClient().connect(path: path)
            t.expect(false, "VNC authentication should be refused")
        } catch {
            t.equal((error as? RFBError)?.message, "server requires VNC authentication",
                    "saying why it can't connect")
        }
    }

    t.suite("RFBClient: a server that offers no security types reports its reason") {
        let path = dir.path("none.sock")
        let fake = try FakeRFB(path: path, securityTypes: nil, securityFailure: "too many clients")
        defer { fake.stop() }
        do {
            try RFBClient().connect(path: path)
            t.expect(false, "a refusal should throw")
        } catch {
            t.equal((error as? RFBError)?.message, "too many clients",
                    "passing the server's reason through")
        }
    }

    t.suite("RFBClient: a failed security handshake reports its reason") {
        let path = dir.path("denied.sock")
        let fake = try FakeRFB(path: path, securityFailure: "authentication failed")
        defer { fake.stop() }
        do {
            try RFBClient().connect(path: path)
            t.expect(false, "a security failure should throw")
        } catch {
            t.equal((error as? RFBError)?.message, "authentication failed",
                    "passing the reason through")
        }
    }

    t.suite("RFBClient: refuses a socket path that won't fit in sockaddr_un") {
        let long = "/tmp/" + String(repeating: "b", count: 200) + ".sock"
        do {
            try RFBClient().connect(path: long)
            t.expect(false, "an over-long path should throw")
        } catch {
            t.equal((error as? RFBError)?.message, "socket path too long", "naming the limit")
        }
    }

    t.suite("RFBClient: a missing socket fails to connect") {
        do {
            try RFBClient().connect(path: dir.path("absent.sock"))
            t.expect(false, "connecting to nothing should throw")
        } catch {
            t.expect((error as? RFBError)?.message.hasPrefix("connect failed:") == true,
                     "with a connect failure, got: \(String(describing: (error as? RFBError)?.message))")
        }
    }

    t.suite("RFBClient: a server that hangs up during the handshake throws") {
        let path = dir.path("hangup.sock")
        let server = try FakeSocketServer(path: path) { _ in }
        defer { server.stop() }
        do {
            try RFBClient().connect(path: path)
            t.expect(false, "a closed connection should throw")
        } catch {
            t.equal((error as? RFBError)?.message, "VNC connection closed",
                    "saying the connection went away")
        }
    }

    t.suite("RFBError: carries its message") {
        t.equal(RFBError("boom").message, "boom", "the message should be stored as given")
    }
}

/// A thread-safe counter for callbacks fired from the RFB reader thread.
private final class FrameCounter {
    private var value = 0
    private let lock = NSLock()
    func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
    func peek() -> Int { lock.lock(); defer { lock.unlock() }; return value }
}
