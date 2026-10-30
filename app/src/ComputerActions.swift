import Foundation

/// Where an action sequence sends its input. QEMU's VNC server turns these into events from
/// the emulated tablet and keyboard, so the guest sees hardware input and nothing has to be
/// running inside the VM. Implemented by RFBClient, whose writes are already thread-safe.
protocol VMInput: AnyObject {
    var screenSize: (width: Int, height: Int) { get }
    func sendPointer(x: Int, y: Int, buttons: UInt8)
    func sendKey(_ keysym: UInt32, down: Bool)
}

extension RFBClient: VMInput {
    var screenSize: (width: Int, height: Int) { (width, height) }
}

/// One list of actions from an MCP client, played into the VM. Blocking (it sleeps between
/// events to let the guest keep up), so it runs on the calling connection's thread and never
/// on the main one.
///
/// Button bits are RFB's: 1 left, 2 middle, 4 right, 8 wheel up, 16 wheel down.
struct ActionRunner {
    /// Why a sequence ended. `after` is how many actions had run by then.
    enum Stop {
        case completed
        /// The display stopped accepting input part-way: the person took control, or the VM went away.
        case interrupted(after: Int)
        case outOfTime(after: Int)
        case failed(String, after: Int)
    }

    /// A key to press: the keysym of the physical key, and whether shift has to be held for
    /// the character it should produce.
    private struct Key {
        let sym: UInt32
        var shifted = false
    }

    private enum Failure: Error {
        case bad(String)
        case interrupted
        case outOfTime
    }

    /// Gaps that keep the guest able to follow. The USB keyboard and tablet are emulated
    /// devices with a finite queue, and an app still laying itself out loses characters typed
    /// into it, so these stay even though the guest's CPU is no longer emulated.
    private static let keyGap = 0.012
    private static let clickGap = 0.05
    private static let doubleClickGap = 0.08
    private static let dragSteps = 12

    private let input: VMInput
    private let deadline: Date
    /// False once the person has taken the VM's mouse and keyboard, or the display is gone.
    private let maySendInput: () -> Bool

    /// The pointer position actions without a coordinate act on, and what is held down.
    private var x: Int
    private var y: Int
    private var buttons: UInt8 = 0
    private var heldKeys = [UInt32]()

    /// Where the pointer was left, so the next list can go on from here. (The person may have
    /// moved it with Take Control since; nothing in RFB can ask the guest where it really is.)
    var position: (x: Int, y: Int) { (x, y) }

    init(input: VMInput, budget: TimeInterval, startingAt pointer: (x: Int, y: Int),
         maySendInput: @escaping () -> Bool) {
        self.input = input
        self.deadline = Date().addingTimeInterval(budget)
        self.maySendInput = maySendInput
        (x, y) = (pointer.x, pointer.y)
    }

    mutating func run(_ actions: [[String: Any]]) -> Stop {
        for (index, action) in actions.enumerated() {
            do {
                try checkpoint()
                try perform(action)
            } catch Failure.interrupted {
                releaseAll()
                return .interrupted(after: index)
            } catch Failure.outOfTime {
                releaseAll()
                return .outOfTime(after: index)
            } catch Failure.bad(let why) {
                releaseAll()
                return .failed("action \(index + 1) (\(action["action"] as? String ?? "?")): \(why)", after: index)
            } catch {
                releaseAll()
                return .failed("action \(index + 1): \(error)", after: index)
            }
        }
        // Nothing stays held past the end of a list: a stuck button or modifier would be
        // waiting for whoever takes control next.
        releaseAll()
        return .completed
    }

    // MARK: actions

    private mutating func perform(_ action: [String: Any]) throws {
        switch (action["action"] as? String ?? "").lowercased() {
        case "screenshot":
            break  // one always comes back at the end of the list
        case "wait":
            try sleep(try duration(action) ?? 1)
        case "mouse_move":
            try move(to: try requiredPoint(action, "coordinate"))
        case "left_click":
            try click(1, action)
        case "right_click":
            try click(4, action)
        case "middle_click":
            try click(2, action)
        case "double_click":
            try click(1, action, times: 2)
        case "triple_click":
            try click(1, action, times: 3)
        case "left_mouse_down":
            if let target = try point(action, "coordinate") { try move(to: target) }
            try press(1)
        case "left_mouse_up":
            if let target = try point(action, "coordinate") { try move(to: target) }
            try release(1)
        case "left_click_drag":
            try drag(action)
        case "scroll":
            try scroll(action)
        case "key":
            try keyCombo(try text(action))
        case "hold_key":
            try holdKey(action)
        case "type":
            try type(try text(action))
        case let other:
            throw Failure.bad(other.isEmpty
                ? "every action needs an \"action\" name"
                : "unknown action \"\(other)\"")
        }
    }

    private mutating func move(to point: (Int, Int)) throws {
        (x, y) = point
        input.sendPointer(x: x, y: y, buttons: buttons)
        try sleep(Self.clickGap)
    }

    private mutating func click(_ mask: UInt8, _ action: [String: Any], times: Int = 1) throws {
        if let target = try point(action, "coordinate") { try move(to: target) }
        let modifiers = try modifierKeys(in: action)
        for sym in modifiers { try hold(sym) }
        for click in 0..<times {
            if click > 0 { try sleep(Self.doubleClickGap) }
            try press(mask)
            try release(mask)
        }
        for sym in modifiers.reversed() { try letGo(sym) }
    }

    private mutating func drag(_ action: [String: Any]) throws {
        if let start = try point(action, "start_coordinate") { try move(to: start) }
        let (endX, endY) = try requiredPoint(action, "coordinate")
        let (fromX, fromY) = (x, y)
        try press(1)
        // Apps only treat it as a drag if they see the pointer travel, so step the way there
        for step in 1...Self.dragSteps {
            let fraction = Double(step) / Double(Self.dragSteps)
            x = fromX + Int((Double(endX - fromX) * fraction).rounded())
            y = fromY + Int((Double(endY - fromY) * fraction).rounded())
            input.sendPointer(x: x, y: y, buttons: buttons)
            try sleep(0.016)
        }
        try release(1)
    }

    private mutating func scroll(_ action: [String: Any]) throws {
        if let target = try point(action, "coordinate") { try move(to: target) }
        let direction = (action["scroll_direction"] as? String ?? "").lowercased()
        let mask: UInt8
        switch direction {
        case "up": mask = 8
        case "down": mask = 16
        case "left", "right":
            throw Failure.bad("""
                the VM's pointer has no horizontal wheel; scroll up or down, or hold shift \
                ("text": "shift") to make the app scroll sideways
                """)
        case "": throw Failure.bad("scroll needs scroll_direction: \"up\" or \"down\"")
        case let other: throw Failure.bad("scroll_direction must be \"up\" or \"down\", not \"\(other)\"")
        }
        let amount = (action["scroll_amount"] as? NSNumber)?.intValue ?? 3
        guard amount > 0, amount <= 100 else {
            throw Failure.bad("scroll_amount must be between 1 and 100")
        }
        let modifiers = try modifierKeys(in: action)
        for sym in modifiers { try hold(sym) }
        for _ in 0..<amount {
            // A wheel click is the bit going down and up again at the same spot
            input.sendPointer(x: x, y: y, buttons: buttons | mask)
            input.sendPointer(x: x, y: y, buttons: buttons)
            try sleep(0.03)
        }
        for sym in modifiers.reversed() { try letGo(sym) }
    }

    private mutating func keyCombo(_ combo: String) throws {
        let (modifiers, key) = try Self.parseCombo(combo)
        for sym in modifiers { try hold(sym) }
        try tap(key)
        for sym in modifiers.reversed() { try letGo(sym) }
    }

    /// Shift for a key that needs it. QEMU's VNC server presses shift itself for A-Z but
    /// not for punctuation, so without this a typed "%" arrives as "5".
    private static let shift: UInt32 = 0xffe1

    private mutating func holdKey(_ action: [String: Any]) throws {
        guard let seconds = try duration(action) else {
            throw Failure.bad("hold_key needs a duration in seconds")
        }
        let (modifiers, key) = try Self.parseCombo(try text(action))
        for sym in modifiers { try hold(sym) }
        if key.shifted { try hold(Self.shift) }
        try hold(key.sym)
        try sleep(seconds)
        try letGo(key.sym)
        if key.shifted { try letGo(Self.shift) }
        for sym in modifiers.reversed() { try letGo(sym) }
    }

    private mutating func type(_ string: String) throws {
        guard !string.isEmpty else { throw Failure.bad("type needs text") }
        for character in string.unicodeScalars {
            try checkpoint()
            try tap(Self.keysym(for: character))
        }
    }

    // MARK: events

    private mutating func press(_ mask: UInt8) throws {
        buttons |= mask
        input.sendPointer(x: x, y: y, buttons: buttons)
        try sleep(Self.clickGap)
    }

    private mutating func release(_ mask: UInt8) throws {
        buttons &= ~mask
        input.sendPointer(x: x, y: y, buttons: buttons)
        try sleep(Self.clickGap)
    }

    private mutating func hold(_ keysym: UInt32) throws {
        heldKeys.append(keysym)
        input.sendKey(keysym, down: true)
        try sleep(Self.keyGap)
    }

    private mutating func letGo(_ keysym: UInt32) throws {
        if let index = heldKeys.lastIndex(of: keysym) { heldKeys.remove(at: index) }
        input.sendKey(keysym, down: false)
        try sleep(Self.keyGap)
    }

    private mutating func tap(_ key: Key) throws {
        if key.shifted { try hold(Self.shift) }
        try hold(key.sym)
        try letGo(key.sym)
        if key.shifted { try letGo(Self.shift) }
    }

    /// Lets go of everything still down, so the VM is left as a person would find it.
    private mutating func releaseAll() {
        for sym in heldKeys.reversed() { input.sendKey(sym, down: false) }
        heldKeys.removeAll()
        if buttons != 0 {
            buttons = 0
            input.sendPointer(x: x, y: y, buttons: 0)
        }
    }

    // MARK: pacing

    /// Stops the sequence if the person has taken control or the 10 minutes are up.
    private func checkpoint() throws {
        guard maySendInput() else { throw Failure.interrupted }
        guard Date() < deadline else { throw Failure.outOfTime }
    }

    private func sleep(_ seconds: Double) throws {
        let until = Date().addingTimeInterval(max(0, seconds))
        while true {
            try checkpoint()
            let left = until.timeIntervalSinceNow
            if left <= 0 { return }
            Thread.sleep(forTimeInterval: min(left, 0.05))
        }
    }

    // MARK: arguments

    /// [x, y] from the action, checked against the screen; nil when the key isn't there.
    private func point(_ action: [String: Any], _ key: String) throws -> (Int, Int)? {
        guard let value = action[key] else { return nil }
        guard let pair = value as? [NSNumber], pair.count == 2 else {
            throw Failure.bad("\(key) must be two numbers, [x, y]")
        }
        let (px, py) = (pair[0].intValue, pair[1].intValue)
        let (width, height) = input.screenSize
        guard width > 0, height > 0 else {
            throw Failure.bad("the VM's display hasn't reported its size yet")
        }
        guard (0..<width).contains(px), (0..<height).contains(py) else {
            throw Failure.bad("\(key) [\(px), \(py)] is off the VM's \(width)x\(height) screen")
        }
        return (px, py)
    }

    /// Same, for an action that can't work without it.
    private func requiredPoint(_ action: [String: Any], _ key: String) throws -> (Int, Int) {
        guard let found = try point(action, key) else { throw Failure.bad("needs \(key): [x, y]") }
        return found
    }

    private func text(_ action: [String: Any]) throws -> String {
        guard let text = action["text"] as? String, !text.isEmpty else {
            throw Failure.bad("needs text")
        }
        return text
    }

    private func duration(_ action: [String: Any]) throws -> Double? {
        guard let value = action["duration"] ?? action["seconds"] else { return nil }
        guard let seconds = (value as? NSNumber)?.doubleValue, seconds >= 0 else {
            throw Failure.bad("duration must be a number of seconds")
        }
        guard seconds <= MCPServer.callBudget else {
            throw Failure.bad("duration can be at most \(Int(MCPServer.callBudget)) seconds")
        }
        return seconds
    }

    /// Modifier keys a click or scroll holds down, from its optional `text` ("ctrl+shift").
    private func modifierKeys(in action: [String: Any]) throws -> [UInt32] {
        guard let text = action["text"] as? String, !text.isEmpty else { return [] }
        return try text.split(separator: "+").map {
            let name = $0.trimmingCharacters(in: .whitespaces)
            guard let sym = Self.modifiers[name.lowercased()] else {
                throw Failure.bad("\"\(name)\" isn't a modifier key; use ctrl, shift, alt or super")
            }
            return sym
        }
    }

    /// "ctrl+shift+t" -> ([Control_L, Shift_L], t). The last part is the key itself.
    private static func parseCombo(_ combo: String) throws -> (modifiers: [UInt32], key: Key) {
        let parts = combo.split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        // A combo ending in "+" means the plus key itself, e.g. "ctrl++"
        var names = parts
        if names.count > 1, names.last == "" {
            names.removeLast()
            names[names.count - 1] = "+"
        }
        guard let last = names.popLast(), !last.isEmpty else {
            throw Failure.bad("\"\(combo)\" isn't a key; try \"Return\", \"ctrl+s\" or \"a\"")
        }
        let held = try names.map { name -> UInt32 in
            guard let sym = modifiers[name.lowercased()] else {
                throw Failure.bad("\"\(name)\" isn't a modifier key; use ctrl, shift, alt or super")
            }
            return sym
        }
        return (held, try named(last))
    }

    /// The key for a key name: "Return", "ctrl", "F5", "a", "/", "percent".
    private static func named(_ name: String) throws -> Key {
        if name.unicodeScalars.count == 1, let scalar = name.unicodeScalars.first,
           scalar.value > 0x20, scalar.value < 0x7f {
            return key(for: scalar.value)
        }
        if let sym = keysyms[name.lowercased()] { return key(for: sym) }
        // A modifier on its own is a key too, which is most of what hold_key is for
        if let sym = modifiers[name.lowercased()] { return Key(sym: sym) }
        throw Failure.bad("""
            unknown key "\(name)". Use a character ("a", "/"), a name ("Return", "Tab", \
            "Escape", "BackSpace", "Delete", "Up", "Page_Down", "F5") or a combo ("ctrl+s")
            """)
    }

    /// The key that types one character. X11 keysyms match Latin-1 code points, and anything
    /// above that uses the Unicode range — which QEMU can only deliver if its keymap has that
    /// character, so non-ASCII text may not arrive.
    private static func keysym(for scalar: Unicode.Scalar) -> Key {
        switch scalar {
        case "\n", "\r": return Key(sym: 0xff0d)  // Return
        case "\t": return Key(sym: 0xff09)  // Tab
        default:
            guard scalar.value <= 0xff else { return Key(sym: 0x0100_0000 | scalar.value) }
            return key(for: scalar.value)
        }
    }

    /// The key to press for a character. QEMU's VNC server handles the two halves of the
    /// keyboard differently, so this does too (see the shift gotcha in AGENTS.md):
    /// a letter carries its own case in the keysym — QEMU lowercases A-Z for the lookup and
    /// re-derives shift from the keysym, overriding whatever the client holds, so sending
    /// shift with it would actually suppress the capital. Punctuation is the other way round:
    /// QEMU ignores the keymap's shift flag, so "%" has to be sent as shift held over "5".
    private static func key(for keysym: UInt32) -> Key {
        if let base = shiftedCharacters[keysym] { return Key(sym: base, shifted: true) }
        return Key(sym: keysym)
    }

    /// Characters a US keyboard only types with shift held, and the key they sit on.
    private static let shiftedCharacters: [UInt32: UInt32] = [
        0x7e: 0x60,  // ~ `
        0x21: 0x31,  // ! 1
        0x40: 0x32,  // @ 2
        0x23: 0x33,  // # 3
        0x24: 0x34,  // $ 4
        0x25: 0x35,  // % 5
        0x5e: 0x36,  // ^ 6
        0x26: 0x37,  // & 7
        0x2a: 0x38,  // * 8
        0x28: 0x39,  // ( 9
        0x29: 0x30,  // ) 0
        0x5f: 0x2d,  // _ -
        0x2b: 0x3d,  // + =
        0x7b: 0x5b,  // { [
        0x7d: 0x5d,  // } ]
        0x7c: 0x5c,  // | \
        0x3a: 0x3b,  // : ;
        0x22: 0x27,  // " '
        0x3c: 0x2c,  // < ,
        0x3e: 0x2e,  // > .
        0x3f: 0x2f,  // ? /
    ]

    private static let modifiers: [String: UInt32] = [
        "ctrl": 0xffe3, "control": 0xffe3, "ctrl_l": 0xffe3, "control_l": 0xffe3,
        "ctrl_r": 0xffe4, "control_r": 0xffe4,
        "shift": 0xffe1, "shift_l": 0xffe1, "shift_r": 0xffe2,
        "alt": 0xffe9, "alt_l": 0xffe9, "alt_r": 0xffea, "option": 0xffe9, "opt": 0xffe9,
        "altgr": 0xffea, "iso_level3_shift": 0xfe03,
        "super": 0xffeb, "super_l": 0xffeb, "super_r": 0xffec,
        "meta": 0xffeb, "cmd": 0xffeb, "command": 0xffeb, "win": 0xffeb, "windows": 0xffeb,
    ]

    private static let keysyms: [String: UInt32] = {
        var table: [String: UInt32] = [
            "return": 0xff0d, "enter": 0xff0d, "kp_enter": 0xff8d,
            "tab": 0xff09, "iso_left_tab": 0xfe20,
            "escape": 0xff1b, "esc": 0xff1b,
            "backspace": 0xff08, "back_space": 0xff08, "bksp": 0xff08,
            "delete": 0xffff, "del": 0xffff, "insert": 0xff63, "ins": 0xff63,
            "home": 0xff50, "end": 0xff57,
            "page_up": 0xff55, "pageup": 0xff55, "pgup": 0xff55, "prior": 0xff55,
            "page_down": 0xff56, "pagedown": 0xff56, "pgdn": 0xff56, "next": 0xff56,
            "left": 0xff51, "up": 0xff52, "right": 0xff53, "down": 0xff54,
            "space": 0x20, "spacebar": 0x20,
            "caps_lock": 0xffe5, "capslock": 0xffe5,
            "num_lock": 0xff7f, "numlock": 0xff7f,
            "scroll_lock": 0xff14, "print": 0xff61, "pause": 0xff13, "menu": 0xff67,
            "sys_req": 0xff15, "linefeed": 0xff0a, "clear": 0xff0b, "begin": 0xff58,
            // Names for characters that can't be written bare in a combo
            "plus": 0x2b, "minus": 0x2d, "equal": 0x3d, "comma": 0x2c, "period": 0x2e,
            "slash": 0x2f, "backslash": 0x5c, "semicolon": 0x3b, "colon": 0x3a,
            "apostrophe": 0x27, "quotedbl": 0x22, "grave": 0x60, "asciitilde": 0x7e,
            "bracketleft": 0x5b, "bracketright": 0x5d, "braceleft": 0x7b, "braceright": 0x7d,
            "parenleft": 0x28, "parenright": 0x29, "less": 0x3c, "greater": 0x3e,
            "bar": 0x7c, "underscore": 0x5f, "asterisk": 0x2a, "question": 0x3f,
            "exclam": 0x21, "at": 0x40, "numbersign": 0x23, "dollar": 0x24,
            "percent": 0x25, "ampersand": 0x26, "asciicircum": 0x5e,
        ]
        for n in 1...12 { table["f\(n)"] = 0xffbe + UInt32(n - 1) }  // F1 … F12
        for n in 0...9 { table["kp_\(n)"] = 0xffb0 + UInt32(n) }
        return table
    }()
}
