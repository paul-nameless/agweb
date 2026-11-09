import Foundation
import AgwebCore

let usage = """
agweb: drive a WebKit browser like playwright-cli. The browser never activates or raises its window.

usage: agweb [-w <workspace>] [-p <profile>] <command> [args] [--options]

A workspace is one agent's tabs; use one per task and close it when done. Its profile (logins, storage) is fixed
when it opens: a fresh one that keeps nothing, or with -p a named one that persists and is shared by every
workspace naming it.

  open [url]                    start the workspace (-p to reuse a named profile's logins)
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
  video-start [path]            record the workspace's tab to MP4 (default .agweb/video-<time>.mp4), with the
              [--max-idle=S]    pointer drawn in; frames only when something changes; time between commands
                                is cut to S seconds (default 1.5, 0 keeps real time)
  video-stop                    finish the recording and print its path
  screenshot [path]             PNG of the viewport (default .agweb/page-<time>.png)
  console                       page console messages since last call
  dialog-accept | dialog-dismiss  how confirm() and prompt() are answered (default dismiss)
  tab-list | tab-new [url] | tab-select <i> | tab-close [i]
  show                          display this workspace's tab in the window (no activation)
  close                         close the workspace; a named profile keeps its logins
  list                          workspaces
  close-all                     close every workspace
  profile-list                  named profiles and the workspaces using them
  profile-delete <name>         delete a named profile and everything it stored
  quit                          stop agweb

--instant                       click, upload, hover, mousemove and type act at once instead of at human speed
-w NAME, --workspace=NAME       default $AGWEB_WORKSPACE, else "default"
-p NAME, --profile=NAME         default $AGWEB_PROFILE, else a fresh profile
`--` ends options, so text that starts with dashes can be passed: agweb type -- --verbose
env: AGWEB_SOCKET runs a separate instance on that socket; AGWEB_APP points at agweb.app
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let env = ProcessInfo.processInfo.environment
var workspace = env["AGWEB_WORKSPACE"].flatMap { $0.isEmpty ? nil : $0 } ?? "default"
var options: [String: String] = [:]
var positional: [String] = []
var input = Array(CommandLine.arguments.dropFirst())[...]
let flags: Set = ["js", "help", "instant"]
let valued: Set = ["profile", "workspace", "max-idle"]
let short = ["-w": "workspace", "-p": "profile"]
while let arg = input.popFirst() {
    if arg == "--" {
        positional += input
        break
    } else if arg == "-h" {
        options["help"] = ""
    } else if let name = short[arg] {
        guard let value = input.popFirst() else { fail("\(arg) needs a value") }
        options[name] = value
    } else if let name = short[String(arg.prefix(2))], arg.dropFirst(2).hasPrefix("=") {
        options[name] = String(arg.dropFirst(3))
    } else if arg.hasPrefix("--"), case let parts = arg.dropFirst(2).split(separator: "=", maxSplits: 1).map(String.init),
              let name = parts.first, flags.contains(name) || valued.contains(name) {
        // Only known options are taken, so `agweb fill e3 --x` still types "--x".
        if valued.contains(name) && parts.count == 1 {
            guard let value = input.popFirst() else { fail("--\(name) needs a value") }
            options[name] = value
        } else {
            options[name] = parts.count > 1 ? parts[1] : ""
        }
    } else {
        positional.append(arg)
    }
}
if let name = options.removeValue(forKey: "workspace") { workspace = name }
if options["profile"] == nil, let profile = env["AGWEB_PROFILE"], !profile.isEmpty { options["profile"] = profile }

guard let command = positional.first, command != "help", options["help"] == nil else {
    print(usage)
    exit(0)
}
var args = Array(positional.dropFirst())
let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

func absolute(_ path: String) -> String {
    URL(fileURLWithPath: (path as NSString).expandingTildeInPath, relativeTo: cwd).standardizedFileURL.path
}

let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
switch command {
case "screenshot":
    args = [absolute(args.first ?? ".agweb/page-\(stamp).png")]
case "video-start":
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
    if ["list", "quit", "close", "close-all"].contains(command) {
        print("agweb is not running")
        exit(0)
    }
    // A held lock means an instance is starting up on this socket; a free one means nobody is.
    if let fd = Agweb.lockOwnership(of: socket) {
        close(fd)
        guard let app = appBundle() else { fail("agweb is not running and its app bundle was not found; set AGWEB_APP") }
        // -g: LaunchServices must not activate the app, or the launch itself steals focus.
        // -n with the socket in its environment: an instance for exactly this socket, whatever else runs.
        let launch = Process()
        launch.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        launch.arguments = ["-g", "-n", "--env", "AGWEB_SOCKET=\(socket)", "-a", app]
        try launch.run()
        launch.waitUntilExit()
    }
    if !waitForSocket(15) { fail("agweb did not start listening on \(socket)") }
}

// Commands time out inside the app (pages 30 s, scripts 30 s); this only catches a wedged app.
// Typing at a person's pace averages about 0.25 s a key, so long text gets longer.
let timeout = 120 + (command == "type" && options["instant"] == nil ? args.joined().count : 0)
guard let response = sendRequest(Request(workspace: workspace, command: command, args: args, options: options), path: socket, timeout: timeout) else {
    fail("no response from agweb on \(socket)")
}
if response.ok {
    print(response.output)
} else {
    fail(response.output)
}
