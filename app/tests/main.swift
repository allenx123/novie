import Foundation

/// The test binary's entry point. See test.sh, and Harness.swift for why it looks like this.
///
/// The suites run on a background thread while the main thread runs its run loop, because
/// MCPServer hops to the main queue for every host callback exactly as it does in the app.
/// A command-line main thread that just ran the tests inline would never drain that queue,
/// and the first `DispatchQueue.main.sync` from a connection thread would deadlock.
// Unbuffered, so the suite that hangs is the last line printed rather than nothing at all
setbuf(stdout, nil)
// Writing to a socket whose peer has gone away is an expected outcome in several suites,
// and must not take the whole run down.
signal(SIGPIPE, SIG_IGN)

// MCPBridge.run() is a loop over stdin that ends in exit(), so it can't be called in
// process. The MCPBridge suite re-runs this same binary with this flag and talks JSON-RPC
// to it over a pipe, which is exactly how an agent uses `NovieMCP --mcp`.
if CommandLine.arguments.contains("--bridge-child") { MCPBridge.run() }

let arguments = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
let runner = TestRunner(filter: arguments.first)

let thread = Thread {
    print("Novie tests")
    print("")
    actionRunnerTests(runner)
    lineReaderTests(runner)
    qmpClientTests(runner)
    rfbClientTests(runner)
    mcpServerTests(runner)
    vmManagerTests(runner)
    mcpBridgeTests(runner)
    let failed = runner.finish()
    // Back to the main thread to leave, so the run loop below stops cleanly
    DispatchQueue.main.async { exit(failed ? 1 : 0) }
}
thread.name = "tests"
thread.stackSize = 8 << 20
thread.start()

RunLoop.main.run()
