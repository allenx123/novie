import AppKit
import Carbon.HIToolbox

/// Shows the VM's screen. Mouse and keyboard go to the VM only while `controlEnabled`
/// is on (the user has taken control); otherwise the view is watch-only.
final class VMDisplayView: NSView {
    var rfb: RFBClient?
    var controlEnabled = false {
        didSet {
            if !controlEnabled { releaseAll() }
            layer?.borderWidth = controlEnabled ? 3 : 0
            window?.invalidateCursorRects(for: self)
        }
    }

    private var buttons: UInt8 = 0
    private var pressedKeys = [UInt16: UInt32]()  // keyCode -> keysym sent on key down
    private var pressedModifiers = Set<UInt32>()
    private var scrollAccum: CGFloat = 0
    private var framePending = false
    private let pendingLock = NSLock()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contentsGravity = .resizeAspect
        layer?.borderColor = NSColor.systemOrange.cgColor
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { controlEnabled }

    /// Called from the RFB thread; coalesces frames onto the main thread.
    func frameUpdated() {
        pendingLock.lock()
        let schedule = !framePending
        framePending = true
        pendingLock.unlock()
        guard schedule else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingLock.lock()
            self.framePending = false
            self.pendingLock.unlock()
            self.layer?.contents = self.rfb?.snapshot()
        }
    }

    func clear() { layer?.contents = nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func resetCursorRects() {
        if controlEnabled { addCursorRect(bounds, cursor: .crosshair) }
    }

    // MARK: mouse

    /// View point -> framebuffer pixel, accounting for the aspect-fit letterboxing.
    private func fbPoint(_ event: NSEvent) -> (Int, Int)? {
        guard let rfb, rfb.width > 0 else { return nil }
        let p = convert(event.locationInWindow, from: nil)
        let scale = min(bounds.width / CGFloat(rfb.width), bounds.height / CGFloat(rfb.height))
        let ox = (bounds.width - CGFloat(rfb.width) * scale) / 2
        let oy = (bounds.height - CGFloat(rfb.height) * scale) / 2
        return (Int((p.x - ox) / scale), Int((p.y - oy) / scale))
    }

    private func pointer(_ event: NSEvent) {
        guard controlEnabled, let (x, y) = fbPoint(event) else { return }
        rfb?.sendPointer(x: x, y: y, buttons: buttons)
    }

    private func button(_ event: NSEvent, mask: UInt8, down: Bool) {
        guard controlEnabled else { return }
        if down { buttons |= mask } else { buttons &= ~mask }
        pointer(event)
    }

    override func mouseDown(with event: NSEvent) {
        if controlEnabled { window?.makeFirstResponder(self) }
        button(event, mask: 1, down: true)
    }
    override func mouseUp(with event: NSEvent) { button(event, mask: 1, down: false) }
    override func rightMouseDown(with event: NSEvent) { button(event, mask: 4, down: true) }
    override func rightMouseUp(with event: NSEvent) { button(event, mask: 4, down: false) }
    override func otherMouseDown(with event: NSEvent) { button(event, mask: 2, down: true) }
    override func otherMouseUp(with event: NSEvent) { button(event, mask: 2, down: false) }
    override func mouseMoved(with event: NSEvent) { pointer(event) }
    override func mouseDragged(with event: NSEvent) { pointer(event) }
    override func rightMouseDragged(with event: NSEvent) { pointer(event) }
    override func otherMouseDragged(with event: NSEvent) { pointer(event) }

    override func scrollWheel(with event: NSEvent) {
        guard controlEnabled, let (x, y) = fbPoint(event) else { return }
        // Trackpads send many small precise deltas; turn them into wheel clicks
        scrollAccum += event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 10 : event.scrollingDeltaY
        while abs(scrollAccum) >= 1 {
            let mask: UInt8 = scrollAccum > 0 ? 8 : 16  // wheel up / down
            rfb?.sendPointer(x: x, y: y, buttons: buttons | mask)
            rfb?.sendPointer(x: x, y: y, buttons: buttons)
            scrollAccum -= scrollAccum > 0 ? 1 : -1
        }
    }

    // MARK: keyboard

    override func keyDown(with event: NSEvent) {
        guard controlEnabled, let sym = keysym(event) else { return }
        pressedKeys[event.keyCode] = sym
        rfb?.sendKey(sym, down: true)
    }

    override func keyUp(with event: NSEvent) {
        guard controlEnabled, let sym = pressedKeys.removeValue(forKey: event.keyCode) else { return }
        rfb?.sendKey(sym, down: false)
    }

    override func flagsChanged(with event: NSEvent) {
        guard controlEnabled else { return }
        // Device-dependent bits tell left and right modifiers apart. Command stays with macOS.
        let raw = UInt32(event.modifierFlags.rawValue & 0xffff)
        let mods: [(UInt32, UInt32)] = [
            (0x0002, 0xffe1), (0x0004, 0xffe2),  // left/right shift
            (0x0001, 0xffe3), (0x2000, 0xffe4),  // left/right control
            (0x0020, 0xffe9), (0x0040, 0xffea),  // left/right option -> Alt
        ]
        for (bit, sym) in mods {
            let down = raw & bit != 0
            if down != pressedModifiers.contains(sym) {
                if down { pressedModifiers.insert(sym) } else { pressedModifiers.remove(sym) }
                rfb?.sendKey(sym, down: down)
            }
        }
        if Int(event.keyCode) == kVK_CapsLock {
            rfb?.sendKey(0xffe5, down: true)
            rfb?.sendKey(0xffe5, down: false)
        }
    }

    override func resignFirstResponder() -> Bool {
        releaseAll()
        return true
    }

    /// Make sure nothing stays stuck down in the VM when we stop forwarding input.
    private func releaseAll() {
        for sym in pressedKeys.values { rfb?.sendKey(sym, down: false) }
        for sym in pressedModifiers { rfb?.sendKey(sym, down: false) }
        pressedKeys.removeAll()
        pressedModifiers.removeAll()
        if buttons != 0, let rfb {
            buttons = 0
            rfb.sendPointer(x: 0, y: 0, buttons: 0)
        }
    }

    private static let specialKeys: [Int: UInt32] = [
        kVK_Return: 0xff0d, kVK_ANSI_KeypadEnter: 0xff8d, kVK_Tab: 0xff09, kVK_Delete: 0xff08,
        kVK_ForwardDelete: 0xffff, kVK_Escape: 0xff1b, kVK_Space: 0x20,
        kVK_LeftArrow: 0xff51, kVK_UpArrow: 0xff52, kVK_RightArrow: 0xff53, kVK_DownArrow: 0xff54,
        kVK_Home: 0xff50, kVK_End: 0xff57, kVK_PageUp: 0xff55, kVK_PageDown: 0xff56, kVK_Help: 0xff63,
        kVK_F1: 0xffbe, kVK_F2: 0xffbf, kVK_F3: 0xffc0, kVK_F4: 0xffc1, kVK_F5: 0xffc2, kVK_F6: 0xffc3,
        kVK_F7: 0xffc4, kVK_F8: 0xffc5, kVK_F9: 0xffc6, kVK_F10: 0xffc7, kVK_F11: 0xffc8, kVK_F12: 0xffc9,
    ]

    private func keysym(_ event: NSEvent) -> UInt32? {
        if let sym = Self.specialKeys[Int(event.keyCode)] { return sym }
        // Ignores control/option but keeps shift, matching what X expects with shift held
        guard let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first else { return nil }
        let v = scalar.value
        if v < 0x20 || v == 0x7f || (0xf700...0xf8ff).contains(v) { return nil }  // control chars, AppKit function keys
        return v <= 0xff ? v : 0x0100_0000 | v
    }
}
