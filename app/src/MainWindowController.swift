import AppKit
import ImageIO
import UniformTypeIdentifiers

/// The window: the VM's screen, a status line, and the two buttons that act on the VM.
/// Everything else reaches the VM over MCP (see MCPServer), which plays mouse and keyboard
/// actions into it through the same VNC connection this window draws from.
final class MainWindowController: NSWindowController, NSWindowDelegate {
    private let vm = VMManager()
    private var rfb: RFBClient?
    private(set) var isSaving = false
    private var mcp: MCPServer?

    private let display = VMDisplayView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800))
    private let statusLabel = NSTextField(labelWithString: "Starting…")
    private let controlButton = NSButton(title: "Take Control", target: nil, action: nil)
    private let restartButton = NSButton(title: "Restart VM", target: nil, action: nil)
    private let bar = NSStackView()
    /// The same setting as Novie → Allow MCP Connections, in the window's title bar: it's what
    /// decides whether a connected agent may drive the VM at all (see MCPServer.isAllowed).
    private let mcpSwitch = NSSwitch()

    /// The guest screen's width / height. The window is kept at this ratio (see
    /// `windowWillResize`), so the VM's screen fills `display` whatever size the window is.
    private var displayAspect: CGFloat = 1280.0 / 800.0

    /// The narrowest the VM's screen may be drawn; the window's minimum size follows from it
    /// and `displayAspect`, so the smallest window is still at the guest's ratio.
    private static let minDisplayWidth: CGFloat = 640

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1296, height: 848),  // 1280x800 plus the margins and bar
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Novie"
        super.init(window: window)
        window.delegate = self
        buildUI()
        buildTitlebarAccessory()
        applyAspect()
        window.center()
        vm.onExit = { [weak self] code in self?.vmExited(code) }
        vm.onResumed = { [weak self] in self?.refreshStatus() }
        vm.onRestoreFailed = { [weak self] log in
            guard let self else { return }
            self.tearDownClients()
            self.note("Could not resume the saved VM state, so booting fresh instead."
                + (log.isEmpty ? "" : "\nQEMU output:\n\(log)"))
            self.startVM()
        }
        startVM()
        startMCPServer()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: UI

    private func buildUI() {
        guard let content = window?.contentView else { return }

        controlButton.setButtonType(.pushOnPushOff)
        controlButton.bezelStyle = .rounded
        controlButton.target = self
        controlButton.action = #selector(toggleControl)
        controlButton.toolTip = "Use the VM's mouse and keyboard yourself (⇧⌘K). Connected agents are locked out while you do."
        // The title changes with the state, so hold the button at the width of the wider of
        // the two: otherwise Restart VM shifts sideways every time control is taken.
        controlButton.title = "Release Control"
        controlButton.sizeToFit()
        let controlWidth = controlButton.frame.width
        controlButton.title = "Take Control"
        controlButton.sizeToFit()
        controlButton.widthAnchor.constraint(
            equalToConstant: max(controlWidth, controlButton.frame.width)).isActive = true
        restartButton.target = self
        restartButton.action = #selector(restartVM)
        restartButton.toolTip = "Boot the VM fresh, discarding anything in it"
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        for view in [statusLabel, NSView(), controlButton, restartButton] { bar.addView(view, in: .leading) }
        bar.orientation = .horizontal
        display.translatesAutoresizingMaskIntoConstraints = false
        bar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(display)
        content.addSubview(bar)
        NSLayoutConstraint.activate([
            display.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            display.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            display.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            bar.topAnchor.constraint(equalTo: display.bottomAnchor, constant: 8),
            bar.leadingAnchor.constraint(equalTo: display.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: display.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
        ])
    }

    /// The MCP toggle lives in the title bar, at the window's top right: it's a setting rather
    /// than an action on the VM, so it stays out of the button bar below the screen.
    private func buildTitlebarAccessory() {
        guard let window else { return }
        let tip = "Let other agents on this Mac work the VM's mouse and keyboard over MCP. "
            + "Same setting as Novie → Allow MCP Connections."
        mcpSwitch.target = self
        mcpSwitch.action = #selector(toggleMCPFromSwitch)
        mcpSwitch.controlSize = .small
        mcpSwitch.toolTip = tip
        mcpSwitch.setAccessibilityLabel("Allow MCP Connections")
        let label = NSTextField(labelWithString: "MCP")
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.toolTip = tip
        let stack = NSStackView(views: [label, mcpSwitch])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 8, bottom: 2, right: 10)
        stack.frame = NSRect(origin: .zero, size: stack.fittingSize)
        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = stack
        accessory.layoutAttribute = .right
        window.addTitlebarAccessoryViewController(accessory)
        syncMCPSwitch()
    }

    // MARK: window size

    /// Everything in the content view that isn't the VM's screen: the margins and the button
    /// bar. It's a fixed size, so the display view grows and shrinks with the window one for
    /// one, and the window's aspect ratio follows from the display's plus this.
    private var chrome: NSSize {
        guard let content = window?.contentView else { return .zero }
        content.layoutSubtreeIfNeeded()  // the bar's height has to be real to be subtracted
        return NSSize(width: content.bounds.width - display.bounds.width,
                      height: content.bounds.height - display.bounds.height)
    }

    /// Sets the smallest window the aspect ratio allows and snaps the current one to it, which
    /// is what keeps the window right after the guest reports a different screen size.
    private func applyAspect() {
        guard let window else { return }
        let chrome = self.chrome
        window.contentMinSize = NSSize(width: Self.minDisplayWidth + chrome.width,
                                       height: (Self.minDisplayWidth / displayAspect).rounded() + chrome.height)
        guard !window.styleMask.contains(.fullScreen) else { return }
        let content = window.contentRect(forFrameRect: window.frame).size
        let snapped = contentSize(matchingAspect: content, from: content)
        guard snapped != content else { return }
        // Resize about the top left, so the title bar stays put
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: snapped))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        window.setFrame(frame, display: true, animate: false)
    }

    /// `proposed` with one side adjusted so the display view ends up at the guest's aspect
    /// ratio. Whichever side the drag changed more is the one that's kept, so dragging any
    /// edge or corner resizes the window and the other side follows.
    private func contentSize(matchingAspect proposed: NSSize, from current: NSSize) -> NSSize {
        let chrome = self.chrome
        if abs(proposed.height - current.height) > abs(proposed.width - current.width) {
            let height = max(proposed.height - chrome.height, 1)
            return NSSize(width: (height * displayAspect).rounded() + chrome.width,
                          height: height + chrome.height)
        }
        let width = max(proposed.width - chrome.width, 1)
        return NSSize(width: width + chrome.width,
                      height: (width / displayAspect).rounded() + chrome.height)
    }

    /// Called for every user resize and for the zoom button: the window only ever takes sizes
    /// that show the VM's screen whole, at one scale in both directions and with no letterboxing.
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard !sender.styleMask.contains(.fullScreen) else { return frameSize }
        let proposed = sender.contentRect(forFrameRect: NSRect(origin: .zero, size: frameSize)).size
        let current = sender.contentRect(forFrameRect: sender.frame).size
        let snapped = contentSize(matchingAspect: proposed, from: current)
        return sender.frameRect(forContentRect: NSRect(origin: .zero, size: snapped)).size
    }

    /// Zoom fills the screen as far as the aspect ratio allows rather than all of it.
    func windowWillUseStandardFrame(_ sender: NSWindow, defaultFrame: NSRect) -> NSRect {
        let chrome = self.chrome
        let available = sender.contentRect(forFrameRect: defaultFrame).size
        let scale = min((available.width - chrome.width) / displayAspect, available.height - chrome.height)
        let content = NSSize(width: (scale * displayAspect).rounded() + chrome.width,
                             height: scale.rounded() + chrome.height)
        var frame = sender.frameRect(forContentRect: NSRect(origin: .zero, size: content))
        frame.origin = NSPoint(x: defaultFrame.midX - frame.width / 2, y: defaultFrame.maxY - frame.height)
        return frame
    }

    /// The one status line. Transient messages (`note`) stay up until the next one or until
    /// something about the VM changes, since there's no output pane to scroll back through.
    private func setStatus(_ text: String) { statusLabel.stringValue = text }

    /// Shows a line and keeps a copy in the system log (Console.app), which is where the
    /// details of anything that goes wrong now live.
    private func note(_ text: String) {
        NSLog("Novie: %@", text)
        setStatus(text.components(separatedBy: "\n")[0])
    }

    private func refreshStatus() {
        if controlButton.state == .on {
            setStatus("You have control — your mouse and keyboard go to the VM")
        } else if !vm.isRunning {
            setStatus("VM stopped. Click Restart VM to boot it again.")
        } else if rfb == nil {
            setStatus(vm.resuming ? "Resuming the VM…" : "Starting the VM…")
        } else if MCPServer.isAllowed {
            setStatus("VM running · MCP connections allowed")
        } else {
            setStatus("VM running · MCP connections off (turn on the MCP switch above)")
        }
    }

    // MARK: VM lifecycle

    private func startVM() {
        display.clear()
        setStatus("Starting the VM…")
        do {
            try vm.start()
        } catch {
            note("Could not start the VM: \(error.localizedDescription)")
            return
        }
        note(vm.resuming
            ? "Resuming the VM from where you left off. VM logs: \(vm.runDir.path)"
            : "VM started; the desktop appears in about half a minute. VM logs: \(vm.runDir.path)")
        setStatus(vm.resuming ? "Resuming the VM…" : "Booting the VM…")
        connectDisplay(attempt: 0)
    }

    /// QEMU creates the VNC socket shortly after launch, so retry for a bit. Once it's
    /// connected, the VM can be both watched and driven.
    private func connectDisplay(attempt: Int) {
        let client = RFBClient()
        client.onFrame = { [weak self] in self?.display.frameUpdated() }
        client.onResize = { [weak self] w, h in
            guard w > 0, h > 0 else { return }
            DispatchQueue.main.async {
                guard let self, self.rfb === client else { return }
                self.displayAspect = CGFloat(w) / CGFloat(h)
                self.applyAspect()
            }
        }
        client.onDisconnect = { [weak self] reason in
            DispatchQueue.main.async {
                guard let self, self.rfb === client else { return }  // not a client we replaced
                self.rfb = nil
                self.display.rfb = nil
                if self.vm.isRunning { self.note("Display disconnected: \(reason)") }
            }
        }
        do {
            try client.connect(path: vm.vncSocketPath)
            rfb = client
            display.rfb = client
            refreshStatus()
        } catch {
            guard attempt < 40, vm.isRunning else {
                note("Could not connect to the VM display: \(error)")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.connectDisplay(attempt: attempt + 1)
            }
        }
    }

    private func tearDownClients() {
        rfb?.disconnect()
        rfb = nil
        display.rfb = nil
    }

    private func vmExited(_ code: Int32) {
        tearDownClients()
        setStatus("VM stopped (exit code \(code)). Click Restart VM to boot it again.")
        if let log = try? String(contentsOf: vm.qemuLogURL, encoding: .utf8), !log.isEmpty {
            NSLog("Novie: QEMU output:\n%@", log)
        }
    }

    func shutdown() {
        mcp?.stop()
        mcp = nil
        tearDownClients()
        vm.stop()
    }

    func discardSavedState() { vm.discardSavedState() }

    /// Saves the VM to disk (see VMManager.suspend) and shuts it down; the next launch resumes it.
    func suspendAndShutdown(completion: @escaping () -> Void) {
        guard vm.isRunning else {
            shutdown()
            completion()
            return
        }
        isSaving = true
        setStatus("Saving the VM so it resumes next time…")
        for control in [controlButton, restartButton, mcpSwitch] as [NSControl] { control.isEnabled = false }
        // Let go of anything held: a key still down when the state is written comes back
        // down when the VM is resumed
        display.controlEnabled = false
        controlButton.state = .off
        syncControlButtonTitle()
        // Stop taking MCP calls first: an action list playing into a VM being written out
        // would be lost half-done
        mcp?.stop()
        mcp = nil
        tearDownClients()
        vm.suspend { error in
            if let error { NSLog("Novie: could not save the VM state: %@", error) }
            completion()
        }
    }

    @objc private func restartVM() {
        if vm.isRunning {
            let alert = NSAlert()
            alert.messageText = "Restart the VM?"
            alert.informativeText = "The VM boots fresh: it runs from RAM, so anything not saved outside it will be lost."
            alert.addButton(withTitle: "Restart")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        tearDownClients()
        vm.stop()
        vm.discardSavedState()  // Restart means a clean boot, not a resume
        startVM()
    }

    // MARK: taking control

    /// While this is on, the window forwards the person's mouse and keyboard to the VM and
    /// MCP clients are refused — including a plain screenshot, since the screen is theirs.
    @objc func toggleControl() {
        let on = controlButton.state == .on
        display.controlEnabled = on
        window?.makeFirstResponder(on ? display : nil)
        syncControlButtonTitle()
        refreshStatus()
    }

    /// The button says what clicking it will do next, so the title follows the state wherever
    /// it is changed from: the button itself, the menu item, or quitting.
    private func syncControlButtonTitle() {
        controlButton.title = controlButton.state == .on ? "Release Control" : "Take Control"
    }

    func toggleControlFromMenu() {
        controlButton.state = controlButton.state == .on ? .off : .on
        toggleControl()
    }

    @objc func showVMLog() {
        NSWorkspace.shared.open(vm.serialLogURL)
    }

    /// Closing the window quits; keep it open while the VM is saved so the status stays visible
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApp.terminate(nil)
        return false
    }
}

// MARK: - MCP

/// An agent connected over MCP drives the VM through this window: its actions go into the
/// same VNC connection the window draws from, so the person sees every click as it happens
/// and can take the mouse and keyboard back at any time.
extension MainWindowController: MCPHost {
    private func startMCPServer() {
        let server = MCPServer(host: self, runDir: vm.runDir)
        do {
            try server.start()
            mcp = server
        } catch {
            note("Could not start the MCP server: \(error.localizedDescription)")
        }
    }

    /// The window's own toggle. It writes the same setting the menu item does, so whichever
    /// one is used, the other follows (the menu item's state is set when its menu opens).
    @objc private func toggleMCPFromSwitch() {
        setMCPAllowed(mcpSwitch.state == .on)
    }

    /// The one way the setting is changed, from the switch or from the menu item.
    func setMCPAllowed(_ allowed: Bool) {
        MCPServer.setAllowed(allowed)
        noteMCPSetting(allowed)
    }

    func noteMCPSetting(_ allowed: Bool) {
        NSLog("Novie: MCP connections %@", allowed ? "allowed" : "off")
        syncMCPSwitch()
        refreshStatus()
    }

    /// Puts the switch where the setting actually is, so it's right at launch and after the
    /// menu item has been used.
    private func syncMCPSwitch() {
        let allowed = MCPServer.isAllowed
        if (mcpSwitch.state == .on) != allowed { mcpSwitch.state = allowed ? .on : .off }
    }

    func mcpInput() -> MCPInput {
        if controlButton.state == .on {
            return .refused("""
                Cannot proceed: the person at the Mac has taken manual control of the VM. Novie \
                won't send input or return a screenshot while they hold it. Try again once they \
                hand control back.
                """)
        }
        guard !isSaving else { return .refused("Novie is quitting and saving the VM.") }
        guard vm.isRunning else {
            return .refused("The VM isn't running. The person at the Mac can start it again with Restart VM.")
        }
        guard let rfb, rfb.width > 0 else {
            return .refused("The VM's display isn't up yet — it may still be starting. Try again in a few seconds.")
        }
        return .ready(rfb)
    }

    func mcpScreenshotJPEG() -> Data? {
        guard let image = rfb?.snapshot() else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    func mcpNote(_ text: String) { note(text) }
}
