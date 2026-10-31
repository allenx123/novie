import Foundation

/// X11 keysyms the assertions below refer to by name.
private enum Sym {
    static let shift: UInt32 = 0xffe1
    static let shiftR: UInt32 = 0xffe2
    static let ctrl: UInt32 = 0xffe3
    static let ctrlR: UInt32 = 0xffe4
    static let alt: UInt32 = 0xffe9
    static let altGr: UInt32 = 0xffea
    static let superL: UInt32 = 0xffeb
    static let returnKey: UInt32 = 0xff0d
    static let tab: UInt32 = 0xff09
    static let escape: UInt32 = 0xff1b
    static let backspace: UInt32 = 0xff08
    static let pageDown: UInt32 = 0xff56
    static let f5: UInt32 = 0xffc2      // 0xffbe + 4
    static let kp3: UInt32 = 0xffb3     // 0xffb0 + 3
    static let space: UInt32 = 0x20
}

private struct Played {
    let stop: ActionRunner.Stop
    let input: FakeInput
    let position: (x: Int, y: Int)
}

/// Plays a list through the real ActionRunner against a recording input.
private func play(_ actions: [[String: Any]],
                  input: FakeInput = FakeInput(),
                  budget: TimeInterval = 20,
                  from pointer: (x: Int, y: Int) = (0, 0),
                  maySend: @escaping () -> Bool = { true }) -> Played {
    var runner = ActionRunner(input: input, budget: budget, startingAt: pointer,
                              maySendInput: maySend)
    let stop = runner.run(actions)
    return Played(stop: stop, input: input, position: runner.position)
}

/// The reason from a `.failed` stop, with the "action N (name): " prefix run() adds stripped
/// off, so each test can assert on the explanation itself. The prefix has its own test.
private func failureMessage(_ stop: ActionRunner.Stop) -> String? {
    guard case .failed(let why, _) = stop else { return nil }
    guard why.hasPrefix("action "), let end = why.range(of: "): ") else { return why }
    return String(why[end.upperBound...])
}

private func isCompleted(_ stop: ActionRunner.Stop) -> Bool {
    if case .completed = stop { return true }
    return false
}

func actionRunnerTests(_ t: TestRunner) {

    // MARK: the invariant that matters most

    t.suite("ActionRunner: nothing is left held, whatever happens") {
        // A stuck button or modifier would be waiting for whoever takes control next, so
        // every exit path has to go through releaseAll().
        let cases: [(String, [[String: Any]], () -> Bool)] = [
            ("completed", [["action": "left_mouse_down", "coordinate": [10, 10]]], { true }),
            ("failed mid-list", [["action": "left_mouse_down", "coordinate": [10, 10]],
                                 ["action": "nonsense"]], { true }),
            ("modifier held at failure", [["action": "hold_key", "text": "ctrl"]], { true }),
            ("interrupted", [["action": "left_mouse_down", "coordinate": [5, 5]],
                             ["action": "wait", "duration": 5]], {
                                 // allowed for the first few checks, then control is taken
                                 InputGate.shared.next() < 4
                             }),
        ]
        for (name, actions, maySend) in cases {
            InputGate.shared.reset()
            let played = play(actions, maySend: maySend)
            let down = played.input.keysDown.sorted()
            let up = played.input.keysUp.sorted()
            t.equal(down, up, "\(name): every key pressed should be released")
            t.equal(played.input.buttonTrail.last ?? 0, 0,
                    "\(name): the last pointer event should have no buttons held")
        }
    }

    // MARK: clicks

    t.suite("ActionRunner: clicks use the right button bits") {
        // RFB button bits: 1 left, 2 middle, 4 right.
        for (action, mask) in [("left_click", UInt8(1)), ("middle_click", UInt8(2)),
                               ("right_click", UInt8(4))] {
            let played = play([["action": action, "coordinate": [40, 50]]])
            t.expect(isCompleted(played.stop), "\(action) should complete")
            t.equal(played.input.buttonTrail, [0, mask, 0], "\(action) should press and release \(mask)")
            t.equal(played.input.positions.first.map { [$0.0, $0.1] } ?? [], [40, 50],
                    "\(action) should move to the coordinate first")
        }
    }

    t.suite("ActionRunner: double and triple clicks repeat the press") {
        let double = play([["action": "double_click", "coordinate": [1, 1]]])
        t.equal(double.input.buttonTrail, [0, 1, 0, 1, 0], "double_click should press twice")
        let triple = play([["action": "triple_click", "coordinate": [1, 1]]])
        t.equal(triple.input.buttonTrail, [0, 1, 0, 1, 0, 1, 0], "triple_click should press three times")
    }

    t.suite("ActionRunner: a click without a coordinate acts where the pointer is") {
        let played = play([["action": "left_click"]], from: (x: 300, y: 400))
        t.equal(played.input.positions.map { [$0.0, $0.1] }, [[300, 400], [300, 400]],
                "the click should land at the starting pointer position")
        t.equal(played.position.x, 300, "x should be unchanged")
        t.equal(played.position.y, 400, "y should be unchanged")
    }

    t.suite("ActionRunner: a click can hold modifiers from its text") {
        let played = play([["action": "left_click", "coordinate": [10, 10], "text": "ctrl+shift"]])
        t.equal(played.input.keysDown, [Sym.ctrl, Sym.shift], "ctrl then shift should go down")
        t.equal(played.input.keysUp, [Sym.shift, Sym.ctrl], "they should be released in reverse")
    }

    t.suite("ActionRunner: left_mouse_down stays held across later actions") {
        let played = play([["action": "left_mouse_down", "coordinate": [10, 10]],
                           ["action": "mouse_move", "coordinate": [60, 70]],
                           ["action": "left_mouse_up", "coordinate": [60, 70]]])
        t.expect(isCompleted(played.stop), "the list should complete")
        // down at 10,10 -> move to 60,70 with the button still held -> up
        t.equal(played.input.buttonTrail, [0, 1, 1, 1, 0],
                "the button should stay held through the move")
        t.equal(played.position.x, 60, "the pointer should end at the last coordinate")
    }

    // MARK: drag

    t.suite("ActionRunner: a drag steps the pointer the whole way") {
        let played = play([["action": "left_click_drag",
                            "start_coordinate": [100, 100], "coordinate": [220, 160]]])
        t.expect(isCompleted(played.stop), "the drag should complete")
        let positions = played.input.positions
        // move to start, press, 12 intermediate steps, release
        t.equal(positions.count, 15, "a drag should send 15 pointer events")
        t.equal([positions[0].0, positions[0].1], [100, 100], "it should start at start_coordinate")
        t.equal([positions.last!.0, positions.last!.1], [220, 160], "it should end at coordinate")
        t.equal(played.input.buttonTrail.first, 0, "the move to the start is button-free")
        t.expect(played.input.buttonTrail[1...13].allSatisfy { $0 == 1 },
                 "the left button should be held for the whole travel")
        t.equal(played.input.buttonTrail.last, 0, "the button should be released at the end")
        // The steps have to actually move, or apps don't see a drag at all
        let distinct = Set(positions.map { "\($0.0),\($0.1)" })
        t.expect(distinct.count > 5, "the intermediate steps should be distinct positions")
    }

    t.suite("ActionRunner: a drag without start_coordinate starts where the pointer is") {
        let played = play([["action": "left_click_drag", "coordinate": [50, 50]]],
                          from: (x: 10, y: 10))
        t.expect(isCompleted(played.stop), "it should complete")
        t.equal([played.input.positions[0].0, played.input.positions[0].1], [10, 10],
                "the press should happen at the starting pointer")
        t.equal(played.position.x, 50, "it should end at the coordinate")
    }

    t.suite("ActionRunner: a drag needs a destination") {
        let played = play([["action": "left_click_drag", "start_coordinate": [1, 1]]])
        t.equal(failureMessage(played.stop), "needs coordinate: [x, y]",
                "a drag with no coordinate should say so")
    }

    // MARK: scroll

    t.suite("ActionRunner: scrolling turns the wheel the right way") {
        // Wheel bits: 8 up, 16 down. One click is the bit going down and up again.
        let up = play([["action": "scroll", "coordinate": [10, 10],
                        "scroll_direction": "up", "scroll_amount": 2]])
        t.equal(up.input.buttonTrail, [0, 8, 0, 8, 0], "two up clicks")
        let down = play([["action": "scroll", "coordinate": [10, 10],
                          "scroll_direction": "DOWN", "scroll_amount": 1]])
        t.equal(down.input.buttonTrail, [0, 16, 0], "direction should be case-insensitive")
    }

    t.suite("ActionRunner: scroll defaults to three clicks") {
        let played = play([["action": "scroll", "scroll_direction": "down"]])
        t.equal(played.input.buttonTrail.filter { $0 == 16 }.count, 3,
                "the default scroll_amount is 3")
    }

    t.suite("ActionRunner: scroll can hold modifiers") {
        let played = play([["action": "scroll", "scroll_direction": "up",
                            "scroll_amount": 1, "text": "shift"]])
        t.equal(played.input.keysDown, [Sym.shift], "shift should be held for a sideways scroll")
        t.equal(played.input.keysUp, [Sym.shift], "and released after")
    }

    t.suite("ActionRunner: bad scroll arguments are explained") {
        let noDirection = play([["action": "scroll"]])
        t.equal(failureMessage(noDirection.stop),
                "scroll needs scroll_direction: \"up\" or \"down\"",
                "a scroll with no direction should say what's missing")

        let sideways = play([["action": "scroll", "scroll_direction": "left"]])
        t.expect(failureMessage(sideways.stop)?.contains("no horizontal wheel") == true,
                 "left/right should explain there is no horizontal wheel")
        let sidewaysRight = play([["action": "scroll", "scroll_direction": "right"]])
        t.expect(failureMessage(sidewaysRight.stop)?.contains("no horizontal wheel") == true,
                 "right should be refused the same way")

        let nonsense = play([["action": "scroll", "scroll_direction": "sideways"]])
        t.expect(failureMessage(nonsense.stop)?.contains("must be \"up\" or \"down\"") == true,
                 "an unknown direction should be named back")

        for amount in [0, -1, 101] {
            let played = play([["action": "scroll", "scroll_direction": "up",
                                "scroll_amount": amount]])
            t.equal(failureMessage(played.stop), "scroll_amount must be between 1 and 100",
                    "scroll_amount \(amount) should be refused")
        }
        let ok = play([["action": "scroll", "scroll_direction": "up", "scroll_amount": 100]])
        t.expect(isCompleted(ok.stop), "scroll_amount 100 is the top of the range and allowed")
    }

    // MARK: keys

    t.suite("ActionRunner: key combos press modifiers around the key") {
        let played = play([["action": "key", "text": "ctrl+s"]])
        t.equal(played.input.keysDown, [Sym.ctrl, 0x73], "ctrl then s")
        t.equal(played.input.keysUp, [0x73, Sym.ctrl], "s then ctrl")

        let three = play([["action": "key", "text": "ctrl+shift+t"]])
        t.equal(three.input.keysDown, [Sym.ctrl, Sym.shift, 0x74], "two modifiers then t")
    }

    t.suite("ActionRunner: every modifier spelling maps to a keysym") {
        let expected: [(String, UInt32)] = [
            ("ctrl", Sym.ctrl), ("control", Sym.ctrl), ("ctrl_l", Sym.ctrl),
            ("control_l", Sym.ctrl), ("ctrl_r", Sym.ctrlR), ("control_r", Sym.ctrlR),
            ("shift", Sym.shift), ("shift_l", Sym.shift), ("shift_r", Sym.shiftR),
            ("alt", Sym.alt), ("alt_l", Sym.alt), ("alt_r", Sym.altGr),
            ("option", Sym.alt), ("opt", Sym.alt), ("altgr", Sym.altGr),
            ("iso_level3_shift", 0xfe03),
            ("super", Sym.superL), ("super_l", Sym.superL), ("super_r", 0xffec),
            ("meta", Sym.superL), ("cmd", Sym.superL), ("command", Sym.superL),
            ("win", Sym.superL), ("windows", Sym.superL),
        ]
        for (name, sym) in expected {
            let played = play([["action": "key", "text": "\(name)+a"]])
            t.equal(played.input.keysDown.first, sym, "\"\(name)\" should be \(String(sym, radix: 16))")
            // Upper case should work too: the lookup is case-insensitive
            let upper = play([["action": "key", "text": "\(name.uppercased())+a"]])
            t.equal(upper.input.keysDown.first, sym, "\"\(name.uppercased())\" should map the same")
        }
    }

    t.suite("ActionRunner: named keys map to their keysyms") {
        let expected: [(String, UInt32)] = [
            ("Return", Sym.returnKey), ("enter", Sym.returnKey), ("kp_enter", 0xff8d),
            ("Tab", Sym.tab), ("iso_left_tab", 0xfe20),
            ("Escape", Sym.escape), ("esc", Sym.escape),
            ("BackSpace", Sym.backspace), ("backspace", Sym.backspace), ("bksp", Sym.backspace),
            ("Delete", 0xffff), ("del", 0xffff), ("Insert", 0xff63), ("ins", 0xff63),
            ("Home", 0xff50), ("End", 0xff57),
            ("Page_Up", 0xff55), ("pageup", 0xff55), ("pgup", 0xff55), ("Prior", 0xff55),
            ("Page_Down", Sym.pageDown), ("pagedown", Sym.pageDown), ("pgdn", Sym.pageDown),
            ("Next", Sym.pageDown),
            ("Left", 0xff51), ("Up", 0xff52), ("Right", 0xff53), ("Down", 0xff54),
            ("space", Sym.space), ("spacebar", Sym.space),
            ("Caps_Lock", 0xffe5), ("capslock", 0xffe5),
            ("Num_Lock", 0xff7f), ("numlock", 0xff7f),
            ("Scroll_Lock", 0xff14), ("Print", 0xff61), ("Pause", 0xff13), ("Menu", 0xff67),
            ("Sys_Req", 0xff15), ("Linefeed", 0xff0a), ("Clear", 0xff0b), ("Begin", 0xff58),
            ("F1", 0xffbe), ("F5", Sym.f5), ("F12", 0xffc9),
            ("kp_0", 0xffb0), ("kp_3", Sym.kp3), ("kp_9", 0xffb9),
        ]
        for (name, sym) in expected {
            let played = play([["action": "key", "text": name]])
            t.expect(isCompleted(played.stop), "\"\(name)\" should be a known key")
            t.equal(played.input.keysDown, [sym],
                    "\"\(name)\" should be keysym \(String(sym, radix: 16))")
        }
    }

    t.suite("ActionRunner: punctuation can be named or written bare") {
        // Both spellings must reach the same key, with shift where the character needs it.
        let named: [(String, UInt32, Bool)] = [
            ("plus", 0x3d, true), ("minus", 0x2d, false), ("equal", 0x3d, false),
            ("comma", 0x2c, false), ("period", 0x2e, false), ("slash", 0x2f, false),
            ("backslash", 0x5c, false), ("semicolon", 0x3b, false), ("colon", 0x3b, true),
            ("apostrophe", 0x27, false), ("quotedbl", 0x27, true), ("grave", 0x60, false),
            ("asciitilde", 0x60, true), ("bracketleft", 0x5b, false),
            ("bracketright", 0x5d, false), ("braceleft", 0x5b, true),
            ("braceright", 0x5d, true), ("parenleft", 0x39, true), ("parenright", 0x30, true),
            ("less", 0x2c, true), ("greater", 0x2e, true), ("bar", 0x5c, true),
            ("underscore", 0x2d, true), ("asterisk", 0x38, true), ("question", 0x2f, true),
            ("exclam", 0x31, true), ("at", 0x32, true), ("numbersign", 0x33, true),
            ("dollar", 0x34, true), ("percent", 0x35, true), ("ampersand", 0x37, true),
            ("asciicircum", 0x36, true),
        ]
        for (name, sym, shifted) in named {
            let played = play([["action": "key", "text": name]])
            t.equal(played.input.keysDown, shifted ? [Sym.shift, sym] : [sym],
                    "\"\(name)\" should press \(shifted ? "shift+" : "")\(String(sym, radix: 16))")
        }
    }

    t.suite("ActionRunner: a lone modifier is a key in its own right") {
        // This is most of what hold_key is for.
        let played = play([["action": "key", "text": "shift"]])
        t.equal(played.input.keysDown, [Sym.shift], "\"shift\" on its own should press shift")
    }

    t.suite("ActionRunner: a combo ending in + means the plus key") {
        let played = play([["action": "key", "text": "ctrl++"]])
        // + is shift over =, so this is ctrl held, then shift, then the = key
        t.equal(played.input.keysDown, [Sym.ctrl, Sym.shift, 0x3d],
                "ctrl++ should be ctrl with shift over =")
        let bare = play([["action": "key", "text": "+"]])
        t.equal(bare.input.keysDown, [Sym.shift, 0x3d], "a bare + should be shift over =")
    }

    t.suite("ActionRunner: bad keys are explained, not guessed at") {
        let unknownKey = play([["action": "key", "text": "Frobnicate"]])
        t.expect(failureMessage(unknownKey.stop)?.contains("unknown key \"Frobnicate\"") == true,
                 "an unknown key name should be quoted back")

        let badModifier = play([["action": "key", "text": "hyper+a"]])
        t.expect(failureMessage(badModifier.stop)?.contains("\"hyper\" isn't a modifier key") == true,
                 "an unknown modifier should be named")

        let blank = play([["action": "key", "text": " "]])
        t.expect(failureMessage(blank.stop)?.contains("isn't a key") == true,
                 "whitespace isn't a key")

        let noText = play([["action": "key"]])
        t.equal(failureMessage(noText.stop), "needs text", "key with no text should say so")

        let emptyText = play([["action": "key", "text": ""]])
        t.equal(failureMessage(emptyText.stop), "needs text", "empty text is the same")

        let badClickModifier = play([["action": "left_click", "text": "hyper"]])
        t.expect(failureMessage(badClickModifier.stop)?.contains("isn't a modifier key") == true,
                 "a click's modifier list is checked too")
    }

    t.suite("ActionRunner: combos tolerate spaces around the parts") {
        let played = play([["action": "key", "text": " ctrl + s "]])
        t.equal(played.input.keysDown, [Sym.ctrl, 0x73], "spaces around the parts are trimmed")
    }

    // MARK: hold_key

    t.suite("ActionRunner: hold_key holds for its duration then lets go") {
        let started = Date()
        let played = play([["action": "hold_key", "text": "a", "duration": 0.3]])
        let elapsed = Date().timeIntervalSince(started)
        t.expect(isCompleted(played.stop), "hold_key should complete")
        t.equal(played.input.keysDown, [0x61], "a should go down once")
        t.equal(played.input.keysUp, [0x61], "and come up once")
        t.expect(elapsed >= 0.28, "it should actually wait (took \(elapsed)s)")
    }

    t.suite("ActionRunner: hold_key handles modifiers and shifted keys") {
        let combo = play([["action": "hold_key", "text": "ctrl+a", "duration": 0.01]])
        t.equal(combo.input.keysDown, [Sym.ctrl, 0x61], "the modifier goes down first")
        t.equal(combo.input.keysUp, [0x61, Sym.ctrl], "and comes up last")

        let shifted = play([["action": "hold_key", "text": "%", "duration": 0.01]])
        t.equal(shifted.input.keysDown, [Sym.shift, 0x35], "%% is shift held over 5")
        t.equal(shifted.input.keysUp, [0x35, Sym.shift], "and shift is released after")
    }

    t.suite("ActionRunner: hold_key needs a duration") {
        let played = play([["action": "hold_key", "text": "a"]])
        t.equal(failureMessage(played.stop), "hold_key needs a duration in seconds",
                "hold_key with no duration should say so")
    }

    // MARK: type

    t.suite("ActionRunner: typing letters carries the case in the keysym") {
        // QEMU derives the case from the keysym and overrides the client's shift, so a
        // capital must NOT be sent with shift held or the capital is suppressed.
        let played = play([["action": "type", "text": "Hi"]])
        t.equal(played.input.keysDown, [0x48, 0x69], "H and i as their own keysyms")
        t.expect(!played.input.keysDown.contains(Sym.shift),
                 "no shift should be sent for a capital letter")
    }

    t.suite("ActionRunner: typing punctuation sends shift over the base key") {
        // The other half of the same gotcha: QEMU ignores the keymap's shift flag, so "%"
        // has to arrive as shift held over "5".
        let played = play([["action": "type", "text": "%"]])
        t.equal(played.input.keysDown, [Sym.shift, 0x35], "%% is shift over 5")
    }

    t.suite("ActionRunner: the AGENTS.md example types correctly") {
        // echo "Novie: 100%" used to arrive as echo 'Novie; 1005'
        let text = "echo \"Novie: 100%\""
        let played = play([["action": "type", "text": text]])
        t.expect(isCompleted(played.stop), "it should complete")
        t.equal(played.input.typedText, text, "the guest should receive the text unchanged")
    }

    t.suite("ActionRunner: every shifted ASCII character survives a round trip") {
        let text = "~!@#$%^&*()_+{}|:\"<>?"
        let played = play([["action": "type", "text": text]])
        t.equal(played.input.typedText, text, "all the shifted characters should round trip")
    }

    t.suite("ActionRunner: unshifted ASCII survives too") {
        let text = "abcXYZ0189 `-=[]\\;',./"
        let played = play([["action": "type", "text": text]])
        t.equal(played.input.typedText, text, "the unshifted half should round trip")
    }

    t.suite("ActionRunner: newlines and tabs become Return and Tab") {
        let played = play([["action": "type", "text": "a\nb\r\tc"]])
        let downs = played.input.keysDown
        t.equal(downs, [0x61, Sym.returnKey, 0x62, Sym.returnKey, Sym.tab, 0x63],
                "\\n and \\r both press Return, \\t presses Tab")
    }

    t.suite("ActionRunner: non-Latin-1 text uses the Unicode keysym range") {
        // Latin-1 maps straight onto keysyms; above that X11 uses 0x01000000 | code point.
        // QEMU can only deliver what its keymap has, which is why this may not arrive.
        let played = play([["action": "type", "text": "é€"]])
        t.equal(played.input.keysDown, [0xe9, 0x0100_20ac],
                "é is its own keysym, € goes in the Unicode range")
    }

    t.suite("ActionRunner: type needs text") {
        t.equal(failureMessage(play([["action": "type"]]).stop), "needs text",
                "type with no text should say so")
        t.equal(failureMessage(play([["action": "type", "text": ""]]).stop), "needs text",
                "type with empty text should say so")
    }

    // MARK: wait and screenshot

    t.suite("ActionRunner: wait sleeps and sends nothing") {
        let started = Date()
        let played = play([["action": "wait", "duration": 0.25]])
        let elapsed = Date().timeIntervalSince(started)
        t.expect(isCompleted(played.stop), "wait should complete")
        t.equal(played.input.events.count, 0, "wait should send no events")
        t.expect(elapsed >= 0.23, "wait should actually wait (took \(elapsed)s)")
    }

    t.suite("ActionRunner: wait defaults to a second, and accepts \"seconds\"") {
        let started = Date()
        let played = play([["action": "wait"]])
        let elapsed = Date().timeIntervalSince(started)
        t.expect(isCompleted(played.stop), "a bare wait should complete")
        t.expect(elapsed >= 0.9 && elapsed < 2, "a bare wait should last about a second (took \(elapsed)s)")

        let alias = play([["action": "wait", "seconds": 0.01]])
        t.expect(isCompleted(alias.stop), "\"seconds\" should work as well as \"duration\"")
    }

    t.suite("ActionRunner: screenshot is a no-op") {
        // A screenshot always comes back at the end of the list anyway.
        let played = play([["action": "screenshot"]])
        t.expect(isCompleted(played.stop), "screenshot should complete")
        t.equal(played.input.events.count, 0, "screenshot should send nothing")
    }

    t.suite("ActionRunner: an empty list does nothing and completes") {
        let played = play([])
        t.expect(isCompleted(played.stop), "an empty list is how a client just looks at the screen")
        t.equal(played.input.events.count, 0, "it should send no events")
    }

    t.suite("ActionRunner: bad durations are refused") {
        t.equal(failureMessage(play([["action": "wait", "duration": "soon"]]).stop),
                "duration must be a number of seconds", "a non-number duration is refused")
        t.equal(failureMessage(play([["action": "wait", "duration": -1]]).stop),
                "duration must be a number of seconds", "a negative duration is refused")
        t.equal(failureMessage(play([["action": "wait", "duration": 601]]).stop),
                "duration can be at most 600 seconds",
                "a duration beyond the call budget is refused")
        t.expect(isCompleted(play([["action": "wait", "duration": 0]]).stop),
                 "zero is a valid duration")
    }

    // MARK: coordinates

    t.suite("ActionRunner: coordinates are checked against the screen") {
        t.expect(isCompleted(play([["action": "mouse_move", "coordinate": [0, 0]]],
                                  input: FakeInput()).stop), "the top left corner is on screen")
        t.expect(isCompleted(play([["action": "mouse_move", "coordinate": [1279, 799]]],
                                  input: FakeInput()).stop), "the bottom right corner is on screen")

        for bad in [[1280, 0], [0, 800], [-1, 0], [0, -1]] {
            let played = play([["action": "mouse_move", "coordinate": bad]], input: FakeInput())
            t.expect(failureMessage(played.stop)?.contains("off the VM's 1280x800 screen") == true,
                     "\(bad) should be reported as off screen, got \(failureMessage(played.stop) ?? "nil")")
        }
    }

    t.suite("ActionRunner: malformed coordinates are explained") {
        t.equal(failureMessage(play([["action": "mouse_move", "coordinate": "middle"]]).stop),
                "coordinate must be two numbers, [x, y]", "a string coordinate is refused")
        t.equal(failureMessage(play([["action": "mouse_move", "coordinate": [1, 2, 3]]]).stop),
                "coordinate must be two numbers, [x, y]", "three numbers are refused")
        t.equal(failureMessage(play([["action": "mouse_move", "coordinate": [1]]]).stop),
                "coordinate must be two numbers, [x, y]", "one number is refused")
        t.equal(failureMessage(play([["action": "mouse_move", "coordinate": ["a", "b"]]]).stop),
                "coordinate must be two numbers, [x, y]", "non-numbers are refused")
        t.equal(failureMessage(play([["action": "mouse_move"]]).stop),
                "needs coordinate: [x, y]", "mouse_move needs a coordinate")
        t.equal(failureMessage(play([["action": "left_click_drag", "start_coordinate": "here",
                                      "coordinate": [1, 1]]]).stop),
                "start_coordinate must be two numbers, [x, y]",
                "the key name is used in the message")
    }

    t.suite("ActionRunner: a display with no size yet refuses coordinates") {
        let played = play([["action": "left_click", "coordinate": [1, 1]]],
                          input: FakeInput(width: 0, height: 0))
        t.equal(failureMessage(played.stop), "the VM's display hasn't reported its size yet",
                "a click before the first frame should say the size is unknown")
    }

    // MARK: unknown actions

    t.suite("ActionRunner: unknown and missing action names are explained") {
        let unknown = play([["action": "teleport"]])
        t.equal(failureMessage(unknown.stop), "unknown action \"teleport\"",
                "an unknown action should be quoted back")
        let missing = play([["coordinate": [1, 1]]])
        t.equal(failureMessage(missing.stop), "every action needs an \"action\" name",
                "an action with no name should say so")
        let wrongType = play([["action": 7]])
        t.equal(failureMessage(wrongType.stop), "every action needs an \"action\" name",
                "a non-string action name is the same as none")
    }

    t.suite("ActionRunner: action names are case-insensitive") {
        let played = play([["action": "LEFT_CLICK", "coordinate": [1, 1]]])
        t.expect(isCompleted(played.stop), "an upper-case action name should still work")
        t.equal(played.input.buttonTrail, [0, 1, 0], "and do the same thing")
    }

    // MARK: how a list stops

    t.suite("ActionRunner: a failure reports which action failed and stops there") {
        let played = play([["action": "mouse_move", "coordinate": [5, 5]],
                           ["action": "teleport"],
                           ["action": "left_click", "coordinate": [9, 9]]])
        guard case .failed(let why, let after) = played.stop else {
            t.expect(false, "the list should have failed")
            return
        }
        t.equal(after, 1, "one action should have run before the failure")
        t.expect(why.contains("action 2 (teleport)"), "the message should name action 2, got: \(why)")
        // Nothing after the failure is sent
        t.equal(played.input.positions.count, 1, "the click after the bad action shouldn't be sent")
    }

    t.suite("ActionRunner: taking control stops a list part-way") {
        InputGate.shared.reset()
        let played = play([["action": "left_click", "coordinate": [1, 1]],
                           ["action": "left_click", "coordinate": [2, 2]],
                           ["action": "left_click", "coordinate": [3, 3]]],
                          maySend: { InputGate.shared.next() < 3 })
        guard case .interrupted(let after) = played.stop else {
            t.expect(false, "the list should have been interrupted, got \(played.stop)")
            return
        }
        t.expect(after < 3, "it should stop before the end, stopped after \(after)")
    }

    t.suite("ActionRunner: control taken before the first action sends nothing") {
        let played = play([["action": "left_click", "coordinate": [1, 1]]], maySend: { false })
        guard case .interrupted(let after) = played.stop else {
            t.expect(false, "it should be interrupted, got \(played.stop)")
            return
        }
        t.equal(after, 0, "no action should have run")
        t.equal(played.input.events.count, 0, "and nothing should have been sent")
    }

    t.suite("ActionRunner: running out of time stops the list") {
        let played = play([["action": "mouse_move", "coordinate": [1, 1]],
                           ["action": "wait", "duration": 30]],
                          budget: 0.3)
        guard case .outOfTime(let after) = played.stop else {
            t.expect(false, "it should run out of time, got \(played.stop)")
            return
        }
        t.equal(after, 1, "the move should have run before the budget ran out")
    }

    t.suite("ActionRunner: a zero budget stops before anything is sent") {
        let played = play([["action": "left_click", "coordinate": [1, 1]]], budget: 0)
        guard case .outOfTime(let after) = played.stop else {
            t.expect(false, "it should run out of time immediately, got \(played.stop)")
            return
        }
        t.equal(after, 0, "nothing should have run")
        t.equal(played.input.events.count, 0, "and nothing should have been sent")
    }

    // MARK: pointer position carries over

    t.suite("ActionRunner: the pointer position is remembered for the next list") {
        let played = play([["action": "mouse_move", "coordinate": [640, 400]]])
        t.equal(played.position.x, 640, "x should be where the list left it")
        t.equal(played.position.y, 400, "y should be where the list left it")

        // Which is what lets a second list carry on from there
        let next = play([["action": "left_click"]], from: played.position)
        t.equal(next.input.positions.map { [$0.0, $0.1] }, [[640, 400], [640, 400]],
                "the next list should start from the remembered position")
    }

    t.suite("ActionRunner: a long list is played in order") {
        let played = play([["action": "mouse_move", "coordinate": [10, 10]],
                           ["action": "left_click"],
                           ["action": "type", "text": "hi"],
                           ["action": "key", "text": "Return"],
                           ["action": "wait", "duration": 0.01]])
        t.expect(isCompleted(played.stop), "the list should complete")
        t.equal(played.input.typedText, "hi\n", "the typing and the Return should both arrive")
        t.equal(played.input.buttonTrail, [0, 1, 0], "the click should be in there once")
    }
}

/// A shared counter for the maySendInput closures, which can't capture local state because
/// ActionRunner takes an @escaping closure.
private final class InputGate {
    static let shared = InputGate()
    private var value = 0
    private let lock = NSLock()
    func reset() { lock.lock(); value = 0; lock.unlock() }
    func next() -> Int {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value
    }
}
