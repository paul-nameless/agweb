import AppKit
import AgwebCore

let usage = """
agweb: drive agweb like playwright-cli. The browser never activates or raises its window.

usage: agweb [-s <session>] <command> [args] [--options]

  open [url] [--profile=NAME]   start a session (default profile = session name; same profile = shared logins;
                                --profile=ephemeral keeps nothing and shares nothing)
  goto <url> | reload | go-back | go-forward
  snapshot                      page as a tree with [ref=eN] handles
  click <ref|css> [--js]        native trusted click: the pointer glides there like a person's
                                (--js: element.click())
  hover <ref|css>               glide the pointer onto an element, so :hover and mouseover fire
  mousemove <x> <y>             glide the pointer to a viewport point (CSS pixels)
  fill <ref|css> <text>         text fields, <select> options, date/colour/number inputs
  type <text>                   insert text at the focused element a character at a time, at a person's pace
                                (input events, not key events; use press for keys)
  press <key>                   native key press: Enter, Tab, Escape, ArrowDown, Shift+Tab, Meta+a
  upload <ref|css> <file...>    click a file input and answer its chooser with the files
  eval <js>                     expression or () => ... in the page; prints JSON
  video-start [path]            record the session's tab to MP4 (default .agweb/video-<time>.mp4), with the
              [--max-idle=S]    pointer drawn in; frames only when something changes; still gaps over S
                                seconds (default 1.5, 0 keeps real time) are shortened to S
  video-stop                    finish the recording and print its path
  screenshot [path]             PNG of the viewport (default .agweb/page-<time>.png)
  console                       page console messages since last call
  dialog accept|dismiss         how confirm() and prompt() are answered (default dismiss)
  tab-list | tab-new [url] | tab-select <i> | tab-close [i]
  show                          display this session's tab in the window (no activation)
  close                         close the session
  list                          sessions
  quit                          stop agweb

--instant                       click, upload, hover, mousemove and type act at once instead of at human speed
session: -s NAME, -s=NAME, --session=NAME or $AGWEB_SESSION; default "default"
`--` ends options, so text that starts with dashes can be passed: agweb type -- --verbose
env: AGWEB_SOCKET runs a separate instance on that socket; AGWEB_APP points at agweb.app
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

var session = ProcessInfo.processInfo.environment["AGWEB_SESSION"] ?? "default"
var options: [String: String] = [:]
var positional: [String] = []
var input = Array(CommandLine.arguments.dropFirst())[...]
let flags: Set = ["js", "help", "instant"]
let valued: Set = ["profile", "session", "max-idle"]
while let arg = input.popFirst() {
    if arg == "--" {
        positional += input
        break
    } else if arg == "-s" || arg == "--session" {
        guard let value = input.popFirst() else { fail("\(arg) needs a session name") }
        session = value
    } else if arg.hasPrefix("-s=") {
        session = String(arg.dropFirst(3))
    } else if arg == "-h" {
        options["help"] = ""
    } else if arg.hasPrefix("--"), case let parts = arg.dropFirst(2).split(separator: "=", maxSplits: 1).map(String.init),
              let name = parts.first, flags.contains(name) || valued.contains(name) {
        // Only known options are taken, so `agweb fill e3 --x` still types "--x".
        if valued.contains(name) && parts.count == 1 {
            guard let value = input.popFirst() else { fail("--\(name) needs a value") }
            options[name] = value
        } else {
            options[name] = parts.count > 1 ? parts[1] : ""
        }
        if name == "session" { session = options.removeValue(forKey: "session")! }
    } else {
        positional.append(arg)
    }
}

guard let command = positional.first, command != "help", options["help"] == nil else {
    print(usage)
    exit(0)
}
var args = Array(positional.dropFirst())
let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

func absolute(_ path: String) -> String {
    URL(fileURLWithPath: (path as NSString).expandingTildeInPath, relativeTo: cwd).standardizedFileURL.path
}

switch command {
case "screenshot":
    let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
    args = [absolute(args.first ?? ".agweb/page-\(stamp).png")]
case "video-start":
    let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
    args = [absolute(args.first ?? ".agweb/video-\(stamp).mp4")]
case "upload" where args.count > 1:
    args = [args[0]] + args.dropFirst().map(absolute)
case "open", "goto", "tab-new":
    // A local file wins over a same-named host, the way a shell user would expect.
    if let target = args.first, FileManager.default.fileExists(atPath: absolute(target)) { args[0] = absolute(target) }
default:
    break
}

let socket = Agweb.socketPath

/// The app bundle this CLI ships in, found through any symlink on PATH.
func appBundle() -> String? {
    if let app = ProcessInfo.processInfo.environment["AGWEB_APP"] { return app }
    guard let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
    let app = exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return app.pathExtension == "app" ? app.path : nil
}

func waitForSocket(_ seconds: Double) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while !isServing(socket) {
        if Date() > deadline { return false }
        usleep(100_000)
    }
    return true
}

if !isServing(socket) {
    if ["list", "quit", "close"].contains(command) {
        print("agweb is not running")
        exit(0)
    }
    let running = !NSRunningApplication.runningApplications(withBundleIdentifier: Agweb.bundleIdentifier).isEmpty
    if running && !Agweb.customSocket {
        // Starting up, or serving a different socket. Never `open` it again: that reopens a running app.
        if !waitForSocket(15) { fail("agweb is running but not serving \(socket); is AGWEB_SOCKET set differently?") }
    } else {
        guard let app = appBundle() else { fail("agweb is not running and its app bundle was not found; set AGWEB_APP") }
        // -g: LaunchServices must not activate the app, or the launch itself steals focus.
        // -n with AGWEB_SOCKET: a separate instance on its own socket, next to the default one.
        let launch = Process()
        launch.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        launch.arguments = Agweb.customSocket ? ["-g", "-n", "--env", "AGWEB_SOCKET=\(socket)", "-a", app] : ["-g", "-a", app]
        try launch.run()
        launch.waitUntilExit()
        if !waitForSocket(15) { fail("agweb did not start listening on \(socket)") }
    }
}

// Commands time out inside the app (pages 30 s, scripts 30 s); this only catches a wedged app.
// Typing at a person's pace averages about 0.25 s a key, so long text gets longer.
let timeout = 120 + (command == "type" && options["instant"] == nil ? args.joined().count : 0)
guard let response = sendRequest(Request(session: session, command: command, args: args, options: options), path: socket, timeout: timeout) else {
    fail("no response from agweb on \(socket)")
}
if response.ok {
    print(response.output)
} else {
    fail(response.output)
}
