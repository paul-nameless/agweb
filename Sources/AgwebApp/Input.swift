import AgwebCore
import AppKit
import WebKit

/// Synthesized AppKit events handed straight to one web view. WebKit turns them into trusted DOM events
/// (isTrusted == true), and because they skip NSWindow.sendEvent they neither hit-test against the tab
/// stacked on top nor activate the app.
@MainActor
enum NativeInput {
    /// WKWebView has no mouseMoved: of its own (real moves come through its tracking area), so this uses the
    /// testing SPI that feeds a move into the same path. Pages only see it because AgentWindow reports key.
    static func move(_ webView: WKWebView, to cssPoint: CGPoint, viewportHeight: CGFloat) throws {
        let simulate = NSSelectorFromString("_simulateMouseMove:")
        guard webView.responds(to: simulate) else { throw Failure("this WebKit has no way to move the pointer; use --instant or click") }
        typealias Send = @convention(c) (AnyObject, Selector, NSEvent) -> Void
        unsafeBitCast(webView.method(for: simulate), to: Send.self)(webView, simulate, try mouse(.mouseMoved, webView, cssPoint, viewportHeight))
    }

    static func button(_ webView: WKWebView, down: Bool, at cssPoint: CGPoint, viewportHeight: CGFloat) throws {
        let event = try mouse(down ? .leftMouseDown : .leftMouseUp, webView, cssPoint, viewportHeight)
        if down { webView.mouseDown(with: event) } else { webView.mouseUp(with: event) }
    }

    private static func mouse(_ type: NSEvent.EventType, _ webView: WKWebView, _ cssPoint: CGPoint, _ viewportHeight: CGFloat) throws -> NSEvent {
        guard let window = webView.window else { throw Failure("tab has no window to receive input") }
        let scale = webView.pageZoom * webView.magnification
        // Under a full-size content view WebKit insets the page below the toolbar; the viewport starts there.
        let topInset = max(0, webView.bounds.height - viewportHeight * scale)
        var point = CGPoint(x: cssPoint.x * scale, y: cssPoint.y * scale + topInset)
        if !webView.isFlipped { point.y = webView.bounds.height - point.y }
        return NSEvent.mouseEvent(with: type, location: webView.convert(point, to: nil), modifierFlags: [],
                                  timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                                  eventNumber: 0, clickCount: type == .mouseMoved ? 0 : 1, pressure: type == .leftMouseDown ? 1 : 0)!
    }

    /// Key events go to the first responder's text input path, so the tab must be first responder while
    /// they are processed. The caller restores the previous responder afterwards.
    static func press(_ webView: WKWebView, combo: String) throws {
        guard let window = webView.window else { throw Failure("tab has no window to receive input") }
        let key = try parse(combo)
        window.makeFirstResponder(webView)
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: key.modifiers,
                                         timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                         context: nil, characters: key.characters, charactersIgnoringModifiers: key.unmodified,
                                         isARepeat: false, keyCode: key.code)!
            if type == .keyDown { webView.keyDown(with: event) } else { webView.keyUp(with: event) }
        }
    }

    private static func function(_ key: Int) -> String { String(UnicodeScalar(UInt32(key))!) }

    private static let named: [String: (UInt16, String)] = [
        "enter": (36, "\r"), "tab": (48, "\t"), "escape": (53, "\u{1b}"), "backspace": (51, "\u{7f}"),
        "delete": (117, function(NSDeleteFunctionKey)), "space": (49, " "),
        "arrowleft": (123, function(NSLeftArrowFunctionKey)), "arrowright": (124, function(NSRightArrowFunctionKey)),
        "arrowdown": (125, function(NSDownArrowFunctionKey)), "arrowup": (126, function(NSUpArrowFunctionKey)),
        "home": (115, function(NSHomeFunctionKey)), "end": (119, function(NSEndFunctionKey)),
        "pageup": (116, function(NSPageUpFunctionKey)), "pagedown": (121, function(NSPageDownFunctionKey)),
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
