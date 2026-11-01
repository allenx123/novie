import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var controller: MainWindowController?
    private var saveVMOnQuit = true

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMenu()
        let controller = MainWindowController()
        controller.showWindow(nil)
        self.controller = controller
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Suspend the VM to disk before quitting so the next launch resumes where it left off
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let controller else { return .terminateNow }
        if controller.isSaving { return .terminateCancel }  // already on its way out
        guard saveVMOnQuit else { return .terminateNow }
        controller.suspendAndShutdown {
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.shutdown()  // don't leave QEMU running (no-op once it's been suspended)
    }

    @objc private func quitWithoutSaving() {
        saveVMOnQuit = false
        controller?.discardSavedState()
        NSApp.terminate(nil)
    }

    @objc private func toggleControl() { controller?.toggleControlFromMenu() }

    /// Other agents reach the app through MCP only while this is on (see MCPServer). The same
    /// setting is in the window's title bar, so the change goes through the window: the switch
    /// there and this item's checkmark both follow it.
    @objc private func toggleMCP(_ item: NSMenuItem) {
        let allowed = !MCPServer.isAllowed
        if let controller { controller.setMCPAllowed(allowed) } else { MCPServer.setAllowed(allowed) }
        item.state = allowed ? .on : .off
    }

    /// The checkmark is set as the menu opens, so it's right even when the setting was last
    /// changed with the window's switch.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleMCP) { item.state = MCPServer.isAllowed ? .on : .off }
        return true
    }

    @objc private func showVMLog() { controller?.showVMLog() }

    private func makeMenu() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        let mcpItem = appMenu.addItem(withTitle: "Allow MCP Connections", action: #selector(toggleMCP), keyEquivalent: "")
        mcpItem.target = self
        mcpItem.state = MCPServer.isAllowed ? .on : .off
        mcpItem.toolTip = "Let other agents on this Mac work the VM's mouse and keyboard over MCP."
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Novie", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Novie", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let quitFresh = appMenu.addItem(withTitle: "Quit Without Saving VM", action: #selector(quitWithoutSaving), keyEquivalent: "q")
        quitFresh.keyEquivalentModifierMask = [.command, .option]
        quitFresh.target = self
        main.addItem(submenu: appMenu, title: "Novie")

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenu: edit, title: "Edit")

        let vm = NSMenu(title: "VM")
        let control = vm.addItem(withTitle: "Take / Release Control", action: #selector(toggleControl), keyEquivalent: "k")
        control.keyEquivalentModifierMask = [.command, .shift]
        control.target = self
        vm.addItem(withTitle: "Show VM Log", action: #selector(showVMLog), keyEquivalent: "").target = self
        main.addItem(submenu: vm, title: "VM")

        return main
    }
}

private extension NSMenu {
    func addItem(submenu: NSMenu, title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }
}

// `--mcp` makes the same binary an MCP server on stdio for the running app; it must come
// before any AppKit use, since that mode is a plain command-line process (see MCPBridge).
if CommandLine.arguments.contains("--mcp") { MCPBridge.run() }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
