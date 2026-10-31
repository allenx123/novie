import Foundation

/// A pipe whose write end a test feeds and whose read end LineReader reads. `closeWriter`
/// is how a test signals end of stream; the pipe is closed once, here, either way.
private final class Pipe2 {
    let readEnd: Int32
    let writeEnd: Int32
    private var writerClosed = false

    init() throws {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { throw TestError("pipe() failed") }
        readEnd = fds[0]
        writeEnd = fds[1]
    }

    func closeWriter() {
        guard !writerClosed else { return }
        writerClosed = true
        close(writeEnd)
    }

    func cleanup() {
        closeWriter()
        close(readEnd)
    }
}

private func withPipe(_ body: (Pipe2) throws -> Void) throws {
    let pipe = try Pipe2()
    defer { pipe.cleanup() }
    try body(pipe)
}

func lineReaderTests(_ t: TestRunner) {

    t.suite("LineReader: splits a stream into lines") {
        try withPipe { pipe in
            writeAll(pipe.writeEnd, [UInt8]("one\ntwo\nthree\n".utf8))
            var reader = LineReader(fd: pipe.readEnd)
            t.equal(reader.next().map { String(decoding: $0, as: UTF8.self) }, "one", "first line")
            t.equal(reader.next().map { String(decoding: $0, as: UTF8.self) }, "two", "second line")
            t.equal(reader.next().map { String(decoding: $0, as: UTF8.self) }, "three", "third line")
        }
    }

    t.suite("LineReader: returns nil at end of stream") {
        try withPipe { pipe in
            writeAll(pipe.writeEnd, [UInt8]("only\n".utf8))
            pipe.closeWriter()
            var reader = LineReader(fd: pipe.readEnd)
            t.equal(reader.next().map { String(decoding: $0, as: UTF8.self) }, "only", "the one line")
            t.expect(reader.next() == nil, "then nil once the writer has closed")
            t.expect(reader.next() == nil, "and nil again, not a hang or a crash")
        }
    }

    t.suite("LineReader: skips empty lines") {
        // Blank lines between messages would otherwise be parsed as JSON and rejected.
        try withPipe { pipe in
            writeAll(pipe.writeEnd, [UInt8]("\n\na\n\n\nb\n".utf8))
            var reader = LineReader(fd: pipe.readEnd)
            t.equal(reader.next().map { String(decoding: $0, as: UTF8.self) }, "a", "blank lines are skipped")
            t.equal(reader.next().map { String(decoding: $0, as: UTF8.self) }, "b", "and between lines too")
        }
    }

    t.suite("LineReader: a line split across writes is reassembled") {
        try withPipe { pipe in
            var reader = LineReader(fd: pipe.readEnd)
            let writer = Thread {
                writeAll(pipe.writeEnd, [UInt8]("hel".utf8))
                usleep(30_000)
                writeAll(pipe.writeEnd, [UInt8]("lo wor".utf8))
                usleep(30_000)
                writeAll(pipe.writeEnd, [UInt8]("ld\n".utf8))
            }
            writer.start()
            t.equal(reader.next().map { String(decoding: $0, as: UTF8.self) }, "hello world",
                    "the reader should wait for the newline")
        }
    }

    t.suite("LineReader: unterminated trailing data is not returned") {
        // A half-written final line is dropped rather than handed over incomplete.
        try withPipe { pipe in
            writeAll(pipe.writeEnd, [UInt8]("done\nhalf".utf8))
            pipe.closeWriter()
            var reader = LineReader(fd: pipe.readEnd)
            t.equal(reader.next().map { String(decoding: $0, as: UTF8.self) }, "done", "the complete line")
            t.expect(reader.next() == nil, "the unterminated remainder is dropped")
        }
    }

    t.suite("LineReader: handles a line longer than its read buffer") {
        // The internal chunk is 64 KiB; a longer line has to span several reads.
        try withPipe { pipe in
            let long = String(repeating: "x", count: 200_000)
            var reader = LineReader(fd: pipe.readEnd)
            let writer = Thread { writeAll(pipe.writeEnd, [UInt8]((long + "\n").utf8)) }
            writer.start()
            let line = reader.next().map { String(decoding: $0, as: UTF8.self) }
            t.equal(line?.count, 200_000, "the whole long line should come back")
            t.equal(line, long, "and be unchanged")
        }
    }

    t.suite("LineReader: carries binary bytes through untouched") {
        try withPipe { pipe in
            writeAll(pipe.writeEnd, [0x01, 0xff, 0x00, 0x7f, 0x0a])
            var reader = LineReader(fd: pipe.readEnd)
            t.equal(reader.next().map { [UInt8]($0) } ?? [], [0x01, 0xff, 0x00, 0x7f],
                    "bytes other than the newline are untouched")
        }
    }
}
