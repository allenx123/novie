import Foundation

/// A tiny test harness, for the same reason build.sh uses plain swiftc: SwiftPM's test
/// support doesn't work on this toolchain (the swift-testing macro plugin can't be resolved,
/// and `swift test --enable-code-coverage` fails outright), so the tests are an ordinary
/// binary compiled from app/src plus app/tests. See test.sh.
///
/// Tests run on a background thread while the main thread runs its run loop, because the
/// code under test hops to the main queue (MCPServer.onMain) exactly as it does in the app.
/// A plain command-line main thread never drains that queue, and `DispatchQueue.main.sync`
/// from a worker would deadlock instead of returning.
final class TestRunner {
    private var suiteName = ""
    private var failures = [String]()
    private var checks = 0
    private var suites = 0
    private let filter: String?

    init(filter: String?) { self.filter = filter }

    /// Runs one group of checks. A throwing suite is a failure, not a crash.
    func suite(_ name: String, _ body: () throws -> Void) {
        if let filter, !name.lowercased().contains(filter.lowercased()) { return }
        suiteName = name
        suites += 1
        let started = Date()
        let before = failures.count
        do {
            try body()
        } catch {
            fail("suite threw: \(error)", file: #file, line: #line)
        }
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        let bad = failures.count - before
        print("  \(bad == 0 ? "ok  " : "FAIL") \(name) (\(ms)ms)")
    }

    func expect(_ condition: Bool, _ message: String,
                file: StaticString = #file, line: UInt = #line) {
        checks += 1
        if !condition { fail(message, file: file, line: line) }
    }

    /// Prints both values when they differ, which is most of what makes a failure readable.
    func equal<T: Equatable>(_ actual: T, _ expected: T, _ message: String,
                             file: StaticString = #file, line: UInt = #line) {
        checks += 1
        if actual != expected {
            fail("\(message)\n       expected: \(expected)\n       actual:   \(actual)",
                 file: file, line: line)
        }
    }

    private func fail(_ message: String, file: StaticString, line: UInt) {
        let where_ = "\(URL(fileURLWithPath: "\(file)").lastPathComponent):\(line)"
        failures.append("[\(suiteName)] \(message)  (\(where_))")
    }

    /// Prints the summary. True if anything failed.
    func finish() -> Bool {
        print("")
        if failures.isEmpty {
            print("All \(checks) checks passed in \(suites) suites.")
            return false
        }
        print("\(failures.count) failure\(failures.count == 1 ? "" : "s") of \(checks) checks:")
        for failure in failures { print("  - \(failure)") }
        return true
    }
}
