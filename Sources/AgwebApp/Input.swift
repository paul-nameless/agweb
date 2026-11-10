import AgwebCore
import AppKit
import WebKit

enum MouseButton: String {
    case left, right, middle

    init(_ name: String?) throws {
        guard let button = MouseButton(rawValue: (name ?? "left").lowercased()) else { throw Failure("button is left, right or middle, not \(name ?? "")") }
        self = button
    }
}

/// Synthesized AppKit events handed straight to one web view. WebKit turns them into trusted DOM events
/// (isTrusted == true), and because they skip NSWindow.sendEvent they neither hit-test against the tab
/// stacked on top nor activate the app. `held` is what the agent is holding down: modifiers from keydown, a
/// button from mousedown.
@MainActor
enum NativeInput {
    /// WKWebView has no mouseMoved: of its own (real moves come through its tracking area), so this uses the
    /// testing SPI that feeds a move into the same path. Pages only see it because AgentWindow reports key.
    /// With a button held it is a drag instead.
    static func move(_ webView: WKWebView, to cssPoint: CGPoint, viewportHeight: CGFloat, held: Held = Held()) throws {
        if let button = held.button {
            let event = try mouse([.left: .leftMouseDragged, .right: .rightMouseDragged, .middle: .otherMouseDragged][button]!, webView, cssPoint, viewportHeight, held: held)
            switch button {
            case .left: webView.mouseDragged(with: event)
            case .right: webView.rightMouseDragged(with: event)
            case .middle: webView.otherMouseDragged(with: event)
            }
            return
        }
        let simulate = NSSelectorFromString("_simulateMouseMove:")
        guard webView.responds(to: simulate) else { throw Failure("this WebKit has no way to move the pointer; use --instant or click") }
        typealias Send = @convention(c) (AnyObject, Selector, NSEvent) -> Void
        unsafeBitCast(webView.method(for: simulate), to: Send.self)(webView, simulate, try mouse(.mouseMoved, webView, cssPoint, viewportHeight, held: held))
    }

    static func button(_ webView: WKWebView, _ button: MouseButton = .left, down: Bool, at cssPoint: CGPoint, viewportHeight: CGFloat,
                       clickCount: Int = 1, held: Held = Held()) throws {
        switch button {
        case .left:
            let event = try mouse(down ? .leftMouseDown : .leftMouseUp, webView, cssPoint, viewportHeight, clickCount: clickCount, held: held)
            if down { webView.mouseDown(with: event) } else { webView.mouseUp(with: event) }
        case .right:
            let event = try mouse(down ? .rightMouseDown : .rightMouseUp, webView, cssPoint, viewportHeight, clickCount: clickCount, held: held)
            if down { webView.rightMouseDown(with: event) } else { webView.rightMouseUp(with: event) }
        case .middle:
            // NSEvent can't set buttonNumber, and a CGEvent made from a screen point lands far off target when the
            // window is on a secondary display; one round-tripped from the NSEvent keeps its window location.
            let base = try mouse(down ? .otherMouseDown : .otherMouseUp, webView, cssPoint, viewportHeight, clickCount: clickCount, held: held)
            guard let cg = base.cgEvent else { throw Failure("could not make a middle-button event") }
            cg.setIntegerValueField(.mouseEventButtonNumber, value: Int64(CGMouseButton.center.rawValue))
            guard let event = NSEvent(cgEvent: cg) else { throw Failure("could not make a middle-button event") }
            if down { webView.otherMouseDown(with: event) } else { webView.otherMouseUp(with: event) }
        }
    }

    /// AppKit has no constructor for scroll events; a CGEvent converts, given the window and a screen location.
    static func wheel(_ webView: WKWebView, at cssPoint: CGPoint, viewportHeight: CGFloat, dx: Int32, dy: Int32) throws {
        guard let window = webView.window,
              let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: -dy, wheel2: -dx, wheel3: 0) else {
            throw Failure("tab has no window to receive input")
        }
        event.location = screenPoint(window, try mouse(.mouseMoved, webView, cssPoint, viewportHeight).locationInWindow)
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
        event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.windowNumber))
        guard let scroll = NSEvent(cgEvent: event) else { throw Failure("could not make a scroll event") }
        webView.scrollWheel(with: scroll)
    }

    /// Quartz screen coordinates (top-left origin) of a window point.
    private static func screenPoint(_ window: NSWindow, _ inWindow: CGPoint) -> CGPoint {
        let inScreen = window.convertPoint(toScreen: inWindow)
        return CGPoint(x: inScreen.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - inScreen.y)
    }

    private static func mouse(_ type: NSEvent.EventType, _ webView: WKWebView, _ cssPoint: CGPoint, _ viewportHeight: CGFloat,
                              clickCount: Int = 1, held: Held = Held()) throws -> NSEvent {
        guard let window = webView.window else { throw Failure("tab has no window to receive input") }
        let scale = webView.pageZoom * webView.magnification
        // Under a full-size content view WebKit insets the page below the toolbar; the viewport starts there.
        let topInset = max(0, webView.bounds.height - viewportHeight * scale)
        var point = CGPoint(x: cssPoint.x * scale, y: cssPoint.y * scale + topInset)
        if !webView.isFlipped { point.y = webView.bounds.height - point.y }
        let pressed: Set<NSEvent.EventType> = [.leftMouseDown, .leftMouseDragged, .rightMouseDown, .rightMouseDragged]
        return NSEvent.mouseEvent(with: type, location: webView.convert(point, to: nil), modifierFlags: held.modifiers,
                                  timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                                  eventNumber: 0, clickCount: type == .mouseMoved ? 0 : clickCount,
                                  pressure: pressed.contains(type) ? 1 : 0)!
    }

    struct Held {
        var modifiers: NSEvent.ModifierFlags = []
        var button: MouseButton?
    }

    /// Key events go to the first responder's text input path, so the tab must be first responder while
    /// they are processed. The caller restores the previous responder afterwards. `phases` picks keydown,
    /// keyup or both; a lone modifier (`keydown Shift`) changes `held` instead of typing.
    static func press(_ webView: WKWebView, combo: String, phases: [NSEvent.EventType] = [.keyDown, .keyUp], held: inout Held) throws {
        guard let window = webView.window else { throw Failure("tab has no window to receive input") }
        window.makeFirstResponder(webView)
        if let (modifier, code) = modifierKeys[combo.lowercased()] {
            for phase in phases {
                if phase == .keyDown { held.modifiers.insert(modifier) } else { held.modifiers.remove(modifier) }
                guard let cg = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: phase == .keyDown) else { continue }
                cg.type = .flagsChanged
                cg.flags = CGEventFlags(rawValue: UInt64(held.modifiers.rawValue))
                if let event = NSEvent(cgEvent: cg) { webView.flagsChanged(with: event) }
            }
            return
        }
        let key = try parse(combo)
        for type in phases {
            let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: key.modifiers.union(held.modifiers),
                                         timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                         context: nil, characters: key.characters, charactersIgnoringModifiers: key.unmodified,
                                         isARepeat: false, keyCode: key.code)!
            if type == .keyDown { webView.keyDown(with: event) } else { webView.keyUp(with: event) }
        }
    }

    private static let modifierKeys: [String: (NSEvent.ModifierFlags, CGKeyCode)] = [
        "shift": (.shift, 56), "control": (.control, 59), "ctrl": (.control, 59), "alt": (.option, 58), "option": (.option, 58),
        "meta": (.command, 55), "command": (.command, 55), "cmd": (.command, 55),
    ]

    private static func function(_ key: Int) -> String { String(UnicodeScalar(UInt32(key))!) }

    private static let named: [String: (UInt16, String)] = [
        "enter": (36, "\r"), "tab": (48, "\t"), "escape": (53, "\u{1b}"), "backspace": (51, "\u{7f}"),
        "delete": (117, function(NSDeleteFunctionKey)), "space": (49, " "),
        "arrowleft": (123, function(NSLeftArrowFunctionKey)), "arrowright": (124, function(NSRightArrowFunctionKey)),
        "arrowdown": (125, function(NSDownArrowFunctionKey)), "arrowup": (126, function(NSUpArrowFunctionKey)),
        "home": (115, function(NSHomeFunctionKey)), "end": (119, function(NSEndFunctionKey)),
        "pageup": (116, function(NSPageUpFunctionKey)), "pagedown": (121, function(NSPageDownFunctionKey)),
        "f1": (122, function(NSF1FunctionKey)), "f2": (120, function(NSF2FunctionKey)), "f3": (99, function(NSF3FunctionKey)),
        "f4": (118, function(NSF4FunctionKey)), "f5": (96, function(NSF5FunctionKey)), "f6": (97, function(NSF6FunctionKey)),
        "f7": (98, function(NSF7FunctionKey)), "f8": (100, function(NSF8FunctionKey)), "f9": (101, function(NSF9FunctionKey)),
        "f10": (109, function(NSF10FunctionKey)), "f11": (103, function(NSF11FunctionKey)), "f12": (111, function(NSF12FunctionKey)),
    ]

    // ANSI layout key codes, so pages see the right event.code and shortcuts reach the right key.
    // Shifted characters map to their unshifted key.
    private static let keys: [Character: (code: UInt16, base: Character)] = {
        var map: [Character: (UInt16, Character)] = [:]
        let unshifted: [(Character, UInt16)] = [
            ("a", 0), ("s", 1), ("d", 2), ("f", 3), ("h", 4), ("g", 5), ("z", 6), ("x", 7), ("c", 8), ("v", 9), ("b", 11),
            ("q", 12), ("w", 13), ("e", 14), ("r", 15), ("y", 16), ("t", 17), ("1", 18), ("2", 19), ("3", 20), ("4", 21),
            ("6", 22), ("5", 23), ("=", 24), ("9", 25), ("7", 26), ("-", 27), ("8", 28), ("0", 29), ("]", 30), ("o", 31),
            ("u", 32), ("[", 33), ("i", 34), ("p", 35), ("l", 37), ("j", 38), ("'", 39), ("k", 40), (";", 41), ("\\", 42),
            (",", 43), ("/", 44), ("n", 45), ("m", 46), (".", 47), ("`", 50),
        ]
        for (char, code) in unshifted { map[char] = (code, char) }
        let shifted: [(Character, Character)] = [
            ("!", "1"), ("@", "2"), ("#", "3"), ("$", "4"), ("%", "5"), ("^", "6"), ("&", "7"), ("*", "8"), ("(", "9"),
            (")", "0"), ("_", "-"), ("+", "="), ("{", "["), ("}", "]"), ("|", "\\"), (":", ";"), ("\"", "'"), ("<", ","),
            (">", "."), ("?", "/"), ("~", "`"),
        ]
        for (char, base) in shifted { map[char] = (map[base]!.0, base) }
        for (char, value) in map where char.isLetter { map[Character(char.uppercased())] = (value.0, char) }
        return map
    }()

    /// Playwright-style combos: "Enter", "Shift+Tab", "Meta+a", "A", "?".
    private static func parse(_ combo: String) throws -> (code: UInt16, characters: String, unmodified: String, modifiers: NSEvent.ModifierFlags) {
        var parts = combo.components(separatedBy: "+")
        // "+" itself, or a combo ending in "+", leaves an empty last part.
        if combo.hasSuffix("+") { parts.removeLast(2); parts.append("+") }
        guard let keyName = parts.popLast(), !keyName.isEmpty else { throw Failure("empty key") }
        var modifiers: NSEvent.ModifierFlags = []
        for part in parts {
            switch part.lowercased() {
            case "shift": modifiers.insert(.shift)
            case "control", "ctrl": modifiers.insert(.control)
            case "alt", "option": modifiers.insert(.option)
            case "meta", "command", "cmd", "controlormeta": modifiers.insert(.command)
            default: throw Failure("unknown modifier \(part)")
            }
        }
        if let (code, characters) = named[keyName.lowercased()] { return (code, characters, characters, modifiers) }
        guard keyName.count == 1, let char = keyName.first else { throw Failure("unknown key \(keyName)") }
        guard let key = keys[char] else { return (0, keyName, keyName, modifiers) }
        if key.base != char { modifiers.insert(.shift) }
        let typed = modifiers.contains(.shift) ? String(char).uppercased() : String(char)
        return (key.code, typed, String(key.base), modifiers)
    }
}
