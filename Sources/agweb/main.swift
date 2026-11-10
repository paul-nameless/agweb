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
  text [target]                 the page's main content (an article) or one element as markdown
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
  fill <target> --secret-cmd CMD | --secret-file PATH
                                a secret: the first line CMD prints (pass show site) or of the file, hidden in replies
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
  pdf [path]                    the page as a PDF, paginated with print styles (--format=A4|Letter|Legal), or
                                --single-page: the screen view on one page (default .agweb/page-<time>.pdf)
  resize <w> <h>                set this tab's viewport size in CSS pixels; the shared window stays as it is
  emulate --color-scheme=dark   prefers-color-scheme for this tab: dark, light or auto
  wait <ms> | <target> [--gone] | --text=… | --url=… | --load   [--timeout=ms, default 30000]
                                sleep, or wait until an element shows (or leaves), text or a URL appears, or the
                                page has loaded with no fetch/XHR in flight
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
  dashboard [--hide]            show (or hide) every tab at once in the window, as the person's ⌘D does;
                                --filename=grid.png also saves a picture of it
  profile-list                  named profiles and the workspaces using them
  profile-delete <name>         delete a named profile and everything it stored
  quit                          stop agweb

--instant                       pointer verbs, upload and type act at once instead of at human speed
--filename=PATH                 snapshot, text, eval, request and response-body: write the answer to a file instead
--download-dir=DIR              where downloads nobody named go (default $AGWEB_DOWNLOAD_DIR, else .agweb/)
--raw                           print only the answer (eval's value, a snapshot), strings unquoted
--json                          print the reply as one JSON object
-w NAME, --workspace=NAME       default $AGWEB_WORKSPACE, else "default"
-p NAME, --profile=NAME         default $AGWEB_PROFILE, else a fresh profile
AGWEB_INSTANT=1                 every command as if --instant
`--` ends options, so text that starts with dashes can be passed: agweb type -- --verbose
env: AGWEB_SOCKET runs a separate instance on that socket; AGWEB_APP points at Agweb.app
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
                  "httpOnly", "secure", "gone", "load", "single-page"]
let valued: Set = ["profile", "workspace", "max-idle", "filename", "size", "filter", "status", "body", "content-type",
                   "header", "domain", "path", "expires", "sameSite", "style", "description", "duration", "browser", "text", "url",
                   "timeout", "color-scheme", "format", "download-dir", "secret-cmd", "secret-file"]
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
        if valued.contains(name) && parts.count == 1 {
            guard let value = input.popFirst() else { fail("--\(name) needs a value") }
            setOption(name, value)
        } else {
            setOption(name, parts.count > 1 ? parts[1] : "")
        }
    } else if arg.hasPrefix("--"), let name = arg.dropFirst(2).split(separator: "=", maxSplits: 1).first,
              name.first?.isLetter == true {
        fail(Commands.unknownOption(String(name), known: flags.union(valued)))
    } else {
        positional.append(arg)
    }
}
if let name = options.removeValue(forKey: "workspace") { workspace = name }
// Only open picks a profile; elsewhere -p must match the workspace's, and an exported default must not fail that.
if positional.first == "open", options["profile"] == nil, let profile = env["AGWEB_PROFILE"], !profile.isEmpty { options["profile"] = profile }
if options["instant"] == nil, env["AGWEB_INSTANT"].map({ !$0.isEmpty }) == true { options["instant"] = "" }

guard let command = positional.first, command != "help", options["help"] == nil else {
    print(usage)
    exit(0)
}
var args = Array(positional.dropFirst())
let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
// Still sent: the app must know the tab list in a raw reply goes unseen.
let raw = options["raw"] != nil
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

// Downloads nobody named land next to the agent's work, like screenshots, not in ~/Downloads.
options["download-dir"] = absolute(options["download-dir"] ?? env["AGWEB_DOWNLOAD_DIR"].flatMap { $0.isEmpty ? nil : $0 } ?? ".agweb")

/// A secret for `fill`, read here so the app never needs the caller's environment (pass's gpg agent, op and bw sessions).
/// Only its first line is used, as `pass show` prints it; failures never echo what the command printed.
func secret(command: String?, file: String?) -> String {
    // Read only a little, so /dev/zero or a command like `yes` can't fill memory.
    let limit = 4096
    var data = Data()
    if let file {
        guard let handle = FileHandle(forReadingAtPath: absolute(file)) else { fail("cannot read \(file)") }
        data = (try? handle.read(upToCount: limit + 1)) ?? Data()
    } else if let command {
        let process = Process(), out = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.standardOutput = out
        do { try process.run() } catch { fail("cannot run --secret-cmd: \(error.localizedDescription)") }
        // Read off the main thread: a grandchild (gpg under pass, waiting on pinentry) can hold the pipe open
        // after the shell is gone, and only exiting ends that wait.
        final class Box: @unchecked Sendable { var data = Data() }
        let box = Box(), done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            box.data = (try? out.fileHandleForReading.read(upToCount: limit + 1)) ?? Data()
            done.signal()
        }
        if done.wait(timeout: .now() + 60) == .timedOut {
            process.terminate()
            fail("--secret-cmd timed out after 60 s")
        }
        data = box.data
        // A long entry (pass with notes) is cut here; only its first line matters.
        let cut = data.count > limit
        if cut { process.terminate() }
        process.waitUntilExit()
        guard cut || process.terminationReason == .exit && process.terminationStatus == 0 else {
            fail(process.terminationReason == .exit ? "--secret-cmd exited with status \(process.terminationStatus)" : "--secret-cmd was killed")
        }
    }
    guard data.prefix(limit).contains(UInt8(ascii: "\n")) || data.count <= limit else { fail("the secret is over \(limit) bytes") }
    let value = String(decoding: data, as: UTF8.self).split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map {
        String($0.hasSuffix("\r") ? $0.dropLast() : $0)
    } ?? ""
    guard !value.isEmpty else { fail("the secret is empty") }
    return value
}

if options["secret-cmd"] != nil || options["secret-file"] != nil {
    let command = options.removeValue(forKey: "secret-cmd"), file = options.removeValue(forKey: "secret-file")
    guard positional.first == "fill" else { fail("--secret-cmd and --secret-file work with fill") }
    guard command == nil || file == nil else { fail("use --secret-cmd or --secret-file, not both") }
    guard positional.count == 2 else { fail("use: agweb fill <target> --secret-cmd CMD | --secret-file PATH (no text)") }
    args.append(secret(command: command, file: file))
    options["secret"] = ""
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
case "pdf":
    options["filename"] = writeAnswerTo ?? absolute(args.first ?? ".agweb/page-\(stamp).pdf")
    writeAnswerTo = nil
case "download", "dashboard":
    if let path = writeAnswerTo { options["filename"] = path }
    writeAnswerTo = nil
case "video-start":
    args = [writeAnswerTo ?? absolute(args.first ?? ".agweb/video-\(stamp).mp4")]
    writeAnswerTo = nil
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
        // AGWEB_AWAKE_SECONDS shortens how long a tab stays visible after a command; the selftest uses it.
        let awake = env["AGWEB_AWAKE_SECONDS"].map { ["--env", "AGWEB_AWAKE_SECONDS=\($0)"] } ?? []
        launch.arguments = ["-g", "-n", "--env", "AGWEB_SOCKET=\(socket)"] + awake + ["-a", app]
        try launch.run()
        launch.waitUntilExit()
    }
    if !waitForSocket(15) { fail("agweb did not start listening on \(socket)") }
}

// Commands time out inside the app (pages 30 s, scripts 30 s, downloads 120 s); this only catches a wedged app.
// Typing at a person's pace averages about 0.25 s a key, so long text gets longer.
// A wait gets its own timeout, or its fixed pause, plus room for the reply.
let waitSeconds = command == "wait" ? max(Int(options["timeout"] ?? "") ?? 30_000, Int(args.first ?? "") ?? 0) / 1000 + 30 : 0
let timeout = max(command == "download" ? 200 : 120, waitSeconds) + (command == "type" && options["instant"] == nil ? args.joined().count : 0)
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
