import CoreGraphics
import Foundation

/// Minimal VNC (RFB 3.8) client for QEMU's built-in VNC server over a Unix socket.
/// Supports Raw, CopyRect and DesktopSize, which is all QEMU needs locally.
final class RFBClient {
    var onResize: ((Int, Int) -> Void)?
    var onFrame: (() -> Void)?
    var onDisconnect: ((String) -> Void)?

    private var fd: Int32 = -1
    private let writeLock = NSLock()
    private let fbLock = NSLock()
    private var fb = [UInt8]()  // BGRX, width*height*4
    private(set) var width = 0
    private(set) var height = 0
    private var closed = false

    func connect(path: String) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw RFBError("socket() failed") }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < maxLen else { throw RFBError("socket path too long") }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            buf.copyBytes(from: path.utf8)
            buf[path.utf8.count] = 0
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, len) }
        }
        guard rc == 0 else {
            close(fd)
            fd = -1
            throw RFBError("connect failed: \(String(cString: strerror(errno)))")
        }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        try handshake()
        let t = Thread { [weak self] in self?.readLoop() }
        t.name = "RFB reader"
        t.start()
    }

    func disconnect() {
        closed = true
        if fd >= 0 { shutdown(fd, SHUT_RDWR) }
    }

    /// Copy of the current framebuffer as an image.
    func snapshot() -> CGImage? {
        fbLock.lock()
        defer { fbLock.unlock() }
        guard width > 0, height > 0 else { return nil }
        guard let provider = CGDataProvider(data: Data(fb) as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    // MARK: input

    func sendPointer(x: Int, y: Int, buttons: UInt8) {
        var msg: [UInt8] = [5, buttons]
        msg += be16(max(0, min(x, width - 1)))
        msg += be16(max(0, min(y, height - 1)))
        write(msg)
    }

    func sendKey(_ keysym: UInt32, down: Bool) {
        var msg: [UInt8] = [4, down ? 1 : 0, 0, 0]
        msg += be32(keysym)
        write(msg)
    }

    // MARK: protocol

    private func handshake() throws {
        let version = try readBytes(12)
        guard String(bytes: version, encoding: .ascii)?.hasPrefix("RFB ") == true else { throw RFBError("not a VNC server") }
        try writeAll(Array("RFB 003.008\n".utf8))
        let count = Int(try readBytes(1)[0])
        if count == 0 { throw RFBError(try readReason()) }
        let types = try readBytes(count)
        guard types.contains(1) else { throw RFBError("server requires VNC authentication") }
        try writeAll([1])  // security type None
        if try readU32() != 0 { throw RFBError(try readReason()) }
        try writeAll([1])  // ClientInit: shared
        let w = Int(try readU16()), h = Int(try readU16())
        _ = try readBytes(16)  // server pixel format; we set our own below
        _ = try readBytes(Int(try readU32()))  // desktop name
        resize(w, h)

        // 32bpp little-endian BGRX, which is what CGImage wants with byteOrder32Little/noneSkipFirst
        var setFormat: [UInt8] = [0, 0, 0, 0, 32, 24, 0, 1]
        setFormat += be16(255) + be16(255) + be16(255) + [16, 8, 0, 0, 0, 0]
        var setEncodings: [UInt8] = [2, 0]
        let encodings: [Int32] = [1, 0, -223]  // CopyRect, Raw, DesktopSize
        setEncodings += be16(encodings.count)
        for e in encodings { setEncodings += be32(UInt32(bitPattern: e)) }
        try writeAll(setFormat + setEncodings)
        requestUpdate(incremental: false)
    }

    private func requestUpdate(incremental: Bool) {
        write([3, incremental ? 1 : 0] + be16(0) + be16(0) + be16(width) + be16(height))
    }

    private func readLoop() {
        do {
            while true {
                let type = try readBytes(1)[0]
                switch type {
                case 0: try readFramebufferUpdate()
                case 1:  // SetColourMapEntries
                    _ = try readBytes(3)
                    _ = try readBytes(Int(try readU16()) * 6)
                case 2: break  // Bell
                case 3:  // ServerCutText
                    _ = try readBytes(3)
                    _ = try readBytes(Int(try readU32()))
                default: throw RFBError("unexpected message \(type)")
                }
            }
        } catch {
            close(fd)
            fd = -1
            if !closed { onDisconnect?((error as? RFBError)?.message ?? "\(error)") }
        }
    }

    private func readFramebufferUpdate() throws {
        _ = try readBytes(1)
        let rects = Int(try readU16())
        for _ in 0..<rects {
            let x = Int(try readU16()), y = Int(try readU16())
            let w = Int(try readU16()), h = Int(try readU16())
            let encoding = Int32(bitPattern: try readU32())
            switch encoding {
            case 0:  // Raw
                let pixels = try readBytes(w * h * 4)
                fbLock.lock()
                pixels.withUnsafeBytes { src in
                    fb.withUnsafeMutableBytes { dst in
                        for row in 0..<h where y + row < height {
                            let n = min(w, width - x) * 4
                            guard n > 0 else { continue }
                            memcpy(dst.baseAddress! + ((y + row) * width + x) * 4, src.baseAddress! + row * w * 4, n)
                        }
                    }
                }
                fbLock.unlock()
            case 1:  // CopyRect
                let sx = Int(try readU16()), sy = Int(try readU16())
                fbLock.lock()
                let rows = sy < y ? Array((0..<h).reversed()) : Array(0..<h)  // handle overlap
                fb.withUnsafeMutableBytes { buf in
                    for row in rows {
                        memmove(buf.baseAddress! + ((y + row) * width + x) * 4,
                                buf.baseAddress! + ((sy + row) * width + sx) * 4, w * 4)
                    }
                }
                fbLock.unlock()
            case -223:  // DesktopSize
                resize(w, h)
            default:
                throw RFBError("unsupported encoding \(encoding)")
            }
        }
        onFrame?()
        requestUpdate(incremental: true)
    }

    private func resize(_ w: Int, _ h: Int) {
        fbLock.lock()
        width = w
        height = h
        fb = [UInt8](repeating: 0, count: w * h * 4)
        fbLock.unlock()
        onResize?(w, h)
    }

    // MARK: socket helpers

    private func readBytes(_ n: Int) throws -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: n)
        var got = 0
        while got < n {
            let r = buf.withUnsafeMutableBytes { recv(fd, $0.baseAddress! + got, n - got, 0) }
            if r <= 0 { throw RFBError(r == 0 ? "VNC connection closed" : String(cString: strerror(errno))) }
            got += r
        }
        return buf
    }

    private func readU16() throws -> UInt16 {
        let b = try readBytes(2)
        return UInt16(b[0]) << 8 | UInt16(b[1])
    }

    private func readU32() throws -> UInt32 {
        let b = try readBytes(4)
        return b.reduce(0) { $0 << 8 | UInt32($1) }
    }

    private func readReason() throws -> String {
        String(decoding: try readBytes(Int(try readU32())), as: UTF8.self)
    }

    private func writeAll(_ bytes: [UInt8]) throws {
        writeLock.lock()
        defer { writeLock.unlock() }
        var sent = 0
        while sent < bytes.count {
            let r = bytes.withUnsafeBytes { send(fd, $0.baseAddress! + sent, bytes.count - sent, 0) }
            if r <= 0 { throw RFBError("VNC write failed") }
            sent += r
        }
    }

    private func write(_ bytes: [UInt8]) {
        guard fd >= 0 else { return }
        try? writeAll(bytes)
    }

    private func be16(_ v: Int) -> [UInt8] { [UInt8((v >> 8) & 0xff), UInt8(v & 0xff)] }
    private func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)] }
}

struct RFBError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}
