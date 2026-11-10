import Foundation
import AgwebCore

let usage = """
agweb: drive a WebKit browser like playwright-cli. The browser never activates or raises its window.

usage: agweb [-w <workspace>] [-p <profile>] <command> [args] [--options]

A workspace is one agent's tabs; use one per task and close it when done. Its profile (logins, storage) is fixed
when it opens: a fresh one that keeps nothing, or with -p a named one that persists and is shared by every
workspace naming it.

Targets: a snapshot ref (e12), role=button[name="Save"], text=Save (substring) or text="Save" (exact), or CSS.

  open [url]                    start the workspace (-p to reuse a named profile's logins)
  goto <url> | reload | go-back | go-forward
  snapshot [target]             page (or one element) as a tree with [ref=eN] handles; same-origin iframes included
  click <target> [right|middle] native trusted click: the pointer glides there like a person's (--js: element.click())
  dblclick <target>             native double click
  check | uncheck <target>      tick or clear a checkbox, radio or switch (no-op when already so)
  drag <from> <to>              press on one element, move to the other with the button held, release
                                (HTML5-draggable sources get DOM drag events instead)
  hover <target>                glide the pointer onto an element, so :hover and mouseover fire
  mousemove <x> <y>             glide the pointer to a viewport point (CSS pixels); drags while a button is down
  mousedown | mouseup [button]  press or release a mouse button at the pointer
  mousewheel <dx> <dy>          scroll at the pointer; positive dy scrolls down
  fill <target> <text>          text fields, <select> options, date/colour/number inputs (--submit: Enter after)
  select <target> <value>       choose a <select> option by value or label
  type <text>                   insert text at the focused element a character at a time, at a person's pace
                                (input events, not key events; --submit: Enter after)
  press <key>                   native key press: Enter, Tab, Escape, ArrowDown, Shift+Tab, Meta+a
  keydown | keyup <key>         hold or release a key
  upload <target> <file...>     click a file input and answer its chooser with the files
  download <target>             click and wait for the download it starts (--filename: where to save it)
  eval <js> [target]            expression or () => ... in the page, or (el) => ... on the target; prints JSON
  highlight [target]            outline an element on the page (--style=css; --hide removes one, or all)
  screenshot [target]           PNG of the viewport or an element (--full-page; --filename, default
                                .agweb/page-<time>.png; .jpg/.jpeg saves JPEG)
  resize <w> <h>                set this tab's viewport size in CSS pixels; the shared window stays as it is
  video-start [path]            record the workspace's tab to MP4 (default .agweb/video-<time>.mp4), with the
              [--max-idle=S]    pointer drawn in; frames only when something changes; time between commands
              [--size=WxH]      is cut to S seconds (default 1.5, 0 keeps real time)
  video-chapter <title>         show a title card in the recording (--description, --duration=ms, default 2000)
  video-stop                    finish the recording and print its path
  console [level]               page console since load: error, warning, info (default) or debug (--clear)
  requests                      fetch/XHR calls and loaded documents since the page loaded, numbered
                                (--filter=regexp, --static adds images/scripts/styles, --clear)
  request | request-headers | request-body | response-headers | response-body <n>
  route <pattern>               answer matching fetch/XHR calls: --status, --body, --content-type, --header="k: v"
  route-list | unroute [pattern]
  cookie-list [--domain --path] | cookie-get <name> | cookie-delete <name> | cookie-clear
  cookie-set <name> <value>     --domain (default: this page's host), --path, --expires=unix, --httpOnly, --secure,
                                --sameSite=Lax|Strict|None
  state-save [file]             cookies and this origin's localStorage as Playwright storage-state JSON
  state-load <file>             put them back; localStorage lands when its origin next loads
  dialog-accept [text] | dialog-dismiss   how confirm() and prompt() are answered (default dismiss)
  tab-list | tab-new [url] | tab-select <i> | tab-close [i]
  show                          display this workspace's tab in the window (no activation)
  close                         close the workspace; a named profile keeps its logins
  list                          workspaces
  close-all                     close every workspace
  profile-list                  named profiles and the workspaces using them
  profile-delete <name>         delete a named profile and everything it stored
  quit                          stop agweb

--instant                       pointer verbs, upload and type act at once instead of at human speed
--filename=PATH                 snapshot, eval, request and response-body: write the answer to a file instead
--raw                           print only the answer (eval's value, a snapshot), strings unquoted
--json                          print the reply as one JSON object
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
// --headed and --browser are accepted for playwright-cli habits; agweb is always headed WebKit.
let flags: Set = ["js", "help", "instant", "headed", "full-page", "submit", "raw", "json", "static", "clear", "hide",
                  "httpOnly", "secure"]
let valued: Set = ["profile", "workspace", "max-idle", "filename", "size", "filter", "status", "body", "content-type",
                   "header", "domain", "path", "expires", "sameSite", "style", "description", "duration", "browser"]
let short = ["-w": "workspace", "-p": "profile"]
func setOption(_ name: String, _ value: String) {
    // --header repeats; the app splits on newlines.
    if name == "header", let earlier = options[name] { options[name] = earlier + "\n" + value } else { options[name] = value }
}
while let arg = input.popFirst() {
    if arg == "--" {
        positional += input
        break
    } else if arg == "-h" {
        options["help"] = ""
    } else if let name = short[arg] {
        guard let value = input.popFirst() else { fail("\(arg) needs a value") }
        setOption(name, value)
    } else if let name = short[String(arg.prefix(2))], arg.dropFirst(2).hasPrefix("=") {
        setOption(name, String(arg.dropFirst(3)))
    } else if arg.hasPrefix("--"), case let parts = arg.dropFirst(2).split(separator: "=", maxSplits: 1).map(String.init),
              let name = parts.first, flags.contains(name) || valued.contains(name) {
        // Only known options are taken, so `agweb fill e3 --x` still types "--x".
        if valued.contains(name) && parts.count == 1 {
            guard let value = input.popFirst() else { fail("--\(name) needs a value") }
            setOption(name, value)
        } else {
            setOption(name, parts.count > 1 ? parts[1] : "")
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
let raw = options.removeValue(forKey: "raw") != nil
let json = options["json"] != nil

func absolute(_ path: String) -> String {
    URL(fileURLWithPath: (path as NSString).expandingTildeInPath, relativeTo: cwd).standardizedFileURL.path
}

/// Prints a reply in the chosen shape and exits with its status.
func finish(_ output: String, ok: Bool) -> Never {
    let text = json ? Output.json(output, ok: ok) : raw && ok ? Output.raw(output) : output
    if ok { print(text) } else if json { print(text) } else { fail(text) }
    exit(ok ? 0 : 1)
}

let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
// The CLI writes the files it can, so the app never needs access to the caller's folders.
var writeAnswerTo = options.removeValue(forKey: "filename").map(absolute)
switch command {
case "screenshot":
    writeAnswerTo = writeAnswerTo ?? options.removeValue(forKey: "path").map(absolute)
    // playwright-cli's positional is a target; a path there is an old habit worth keeping.
    if writeAnswerTo == nil, let first = args.first, [".png", ".jpg", ".jpeg"].contains(where: first.lowercased().hasSuffix) {
        writeAnswerTo = absolute(first)
        args.removeFirst()
    }
    options["filename"] = writeAnswerTo ?? absolute(".agweb/page-\(stamp).png")
    writeAnswerTo = nil
case "download":
    if let path = writeAnswerTo { options["filename"] = path }
    writeAnswerTo = nil
case "video-start":
    args = [absolute(args.first ?? ".agweb/video-\(stamp).mp4")]
case "upload" where args.count > 1:
    args = [args[0]] + args.dropFirst().map(absolute)
case "state-save":
    writeAnswerTo = writeAnswerTo ?? absolute(args.first ?? ".agweb/state-\(stamp).json")
    args = []
case "state-load":
    guard let file = writeAnswerTo ?? args.first.map(absolute) else { fail("missing <file>") }
    guard let data = FileManager.default.contents(atPath: file) else { fail("cannot read \(file)") }
    args = [String(decoding: data, as: UTF8.self)]
    writeAnswerTo = nil
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
        finish(command == "list" && json ? "{\"workspaces\":[]}" : "agweb is not running", ok: true)
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

// Commands time out inside the app (pages 30 s, scripts 30 s, downloads 120 s); this only catches a wedged app.
// Typing at a person's pace averages about 0.25 s a key, so long text gets longer.
let timeout = (command == "download" ? 200 : 120) + (command == "type" && options["instant"] == nil ? args.joined().count : 0)
guard let response = sendRequest(Request(workspace: workspace, command: command, args: args, options: options), path: socket, timeout: timeout) else {
    fail("no response from agweb on \(socket)")
}
guard response.ok, let path = writeAnswerTo else { finish(response.output, ok: response.ok) }

// Replace the answer with the file it went to; the page sections stay.
let sections = Output.sections(response.output)
guard let answer = sections.firstIndex(where: { !["Page", "Tabs", "Events"].contains($0.title) }) else { finish(response.output, ok: true) }
do {
    try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data((sections[answer].body + "\n").utf8).write(to: URL(fileURLWithPath: path))
} catch {
    fail("cannot write \(path): \(error.localizedDescription)")
}
finish(sections.enumerated().map { i, section in "### \(section.title)\n" + (i == answer ? path : section.body) }.joined(separator: "\n"), ok: true)
