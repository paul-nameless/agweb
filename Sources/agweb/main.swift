import Foundation
import AgwebCore

let usage = """
agweb: drive a WebKit browser like playwright-cli. The browser never activates or raises its window.

usage: agweb [-w <workspace>] [-p <profile>] <command> [args] [--options]

A workspace is one agent's tabs; use one per task and close it when done. Its profile (logins, storage) is fixed
when it opens: a fresh one that keeps nothing, or with -p a named one that persists and is shared by every
workspace naming it.

Targets: a snapshot ref (e12), role=button[name="Save"] or role=heading[level=1], text=Save (substring) or text="Save" (exact), or CSS; add >> nth=N to pick one of several (-1 is the last).

  open [url]                    start the workspace (-p to reuse a named profile's logins)
  goto <url> | reload | go-back | go-forward
                                a URL that answers with a file (open and tab-new too): waits for the download
                                and prints its path (--filename: where to save it)
                                --basic-auth USER --secret-cmd CMD (or USER:PASSWORD), on open too: the login a 401
                                asks for, for that URL's site, in memory until the workspace closes (with -p, an
                                accepted one serves the profile's workspaces until agweb quits)
                                --header "k: v" (repeats), on open too: sent with that page load and its redirects,
                                other hosts too (an API page needing a header), not its images, scripts or fetches
  history                       the tab's back-forward list: where go-back (-1) and go-forward (+1) lead, current is 0
                                (the 10 around the current one; --max-results=N for more)
  snapshot [target]             page (or one element) as a tree with [ref=eN] handles; iframes included
                                (--diff: only what changed since the last snapshot; an element keeps its ref)
  find <text>                   the whole page's snapshot lines containing text, each with the lines above it and up to
                                10 after it in its container (--max-results=20; --filename saves every match)
  markdown [target]             the page's main content (an article) or one element as markdown (--all: the whole page)
  click <target> [right|middle] native trusted click: the pointer glides there like a person's (--js: element.click());
                                fails if something covers the target, such as a cookie dialog (--force: click anyway)
  dblclick <target>             native double click
  check | uncheck <target>      tick or clear a checkbox, radio or switch (no-op when already so)
  drag <from> <to>              press on one element, move to the other with the button held, release
                                (HTML5-draggable sources get DOM drag events instead)
  hover <target>                glide the pointer onto an element, so :hover and mouseover fire
  mousemove <x> <y>             glide the pointer to a viewport point (CSS pixels); drags while a button is down
  mousedown | mouseup [button]  press or release a mouse button at the pointer
  mousewheel <dx> <dy> [target] scroll what is under the pointer, as a person's wheel does (an inner box or
                                editor before the page); with a target, the pointer moves onto it first; positive dy down
  fill <target> <text>          text fields, <select> options, date/colour/number inputs (--submit: Enter after)
  fill <target> --secret-cmd CMD | --secret-file PATH
                                a secret: the first line CMD prints (pass show site) or of the file, hidden in replies
  select <target> <value>       choose a <select> option by value or label
  type <text>                   insert text at the focused element a character at a time, at a person's pace
                                (input events, not key events; --submit: Enter after)
  press <key>                   native key press: Enter, Tab, Escape, ArrowDown, Shift+Tab, Meta+a, KeyW
                                (Meta+c, Meta+x and Meta+v use the workspace clipboard, never the person's)
  keydown | keyup <key>         hold or release a key
  upload <target> <file...>     click a file input and answer its chooser with the files
  download <target>             click and wait for the download it starts (--filename: where to save it)
  eval <js> [target]            expression or () => ... in the page, or (el) => ... on the target; prints JSON
                                (js is the same command, for sandboxes that refuse the word eval); waits up to
                                30 s for a Promise
  scroll-into-view <target>     glide an element to the middle of the viewport unless it is in view already
                                (--instant jumps; clicks, hovers and drags scroll the same way)
  highlight [target]            outline an element on the page (--style=css; --hide removes one, or all)
  screenshot [target]           PNG of the viewport or a whole element, one pixel per CSS pixel (--full-page, a
                                scrolling message list included; --full-resolution: the screen's pixels, 2x on
                                Retina, for small text or icons; --filename, default .agweb/page-<time>.png;
                                .jpg/.jpeg saves JPEG)
  pdf [path]                    the page as a PDF, paginated with print styles (--format=A4|Letter|Legal), or
                                --single-page: the screen view on one page (default .agweb/page-<time>.pdf)
  resize <w> <h>                set this tab's viewport size in CSS pixels; the shared window stays as it is
  emulate --color-scheme=dark   prefers-color-scheme for this tab: dark, light or auto
  emulate --device=iphone       this tab as an iPhone shows it: 390x844 viewport, iPhone user agent, then a reload;
                                tabs it opens inherit it (off undoes it; touch and hover/pointer media stay the Mac's)
  wait <ms> | <target> [--gone | --enabled] | --text=… | --url=… | --load   [--timeout=ms, default 30000]
                                sleep, or wait until an element shows (or leaves), text or a URL appears, or the
                                page has loaded with no fetch/XHR in flight
  video-start [path]            record the workspace's tab to MP4 (default .agweb/video-<time>.mp4), with the
              [--max-idle=S]    pointer drawn in (hand, I-beam or arrow), 30 fps; time between commands
              [--size=WxH]      is cut to S seconds (default 1.5, 0 keeps real time); wait <ms> shows in full;
                                resize 1280 720 with --size=1280x720 makes about half the file of 1920x1080
  video-stop                    finish the recording and print its path
  console [level]               page console since load: error, warning, info (default) or debug (--clear)
  requests                      fetch/XHR calls and loaded documents since the page loaded, numbered
                                (--filter=regexp, --static adds images/scripts/styles, --clear)
  request | request-headers | request-body | response-headers | response-body <n>
  route <pattern>               answer matching fetch/XHR calls: --status, --body, --content-type, --header="k: v"
  route-list | unroute [pattern]
  media <file>                  getUserMedia gets the file, looped, as camera (its video) and microphone (its audio)
                                instead of devices; --camera FILE / --mic FILE set one; off removes them
  geolocation <lat> <lon>       navigator.geolocation answers with this position (--accuracy=M, default 20); off
  cookie-list [--domain --path] | cookie-get <name> | cookie-delete <name> | cookie-clear
  cookie-set <name> <value>     --domain (default: this page's host), --path, --expires=unix, --httpOnly, --secure,
                                --sameSite=Lax|Strict|None
  clipboard                     what pages in this workspace copied (a copy button, Meta+c); --raw prints the text.
                                Pages never write the person's clipboard while agents drive them
  clipboard-set <text>          put text in the workspace clipboard: press Meta+v pastes it, page clipboard reads get it
  state-save [file]             cookies and this origin's localStorage as Playwright storage-state JSON
  state-load <file>             put them back; localStorage lands when its origin next loads
  dialog-accept [text] | dialog-dismiss   how confirm() and prompt() are answered (default dismiss)
  tab-list | tab-new [url] | tab-select <i> | tab-close [i]
  show                          display this workspace's tab in the window (no activation; brings back a
                                minimized or hidden window)
  ask <message> [target]        hand the tab to the person: a bar with Done over it, without taking focus; returns on
                                Done, or when target/--text/--url appears (--timeout, default 600000 ms, up to 1 h)
  close                         close the workspace; a named profile keeps its logins
  list | tree                   every agent's workspaces, not just yours, as a tree: profile, workspaces, tabs, and when
                                each was last used
  close-all                     DANGEROUS: closes every agent's workspaces and their tabs, not just yours; only when
                                the person asks for all of them. To clean up your own: agweb -w NAME close
  dashboard [--hide]            show (or hide) every tab at once in the window, as the person's ⌘D does;
                                --filename=grid.png also saves a picture of it
  profile [list]                named profiles, the workspaces using them and their proxies (never a password)
  profile set <name> proxy <url>  the profile's pages, fetch, WebSockets and downloads go through socks5://, http:// or
                                https:// [user[:password]@]host:port; --secret-cmd/--secret-file keep the password out
                                of your transcript. If the proxy is down or refuses, loads fail, never go direct;
                                localhost, this Mac's own addresses and WebRTC skip it (a page can learn the real IP).
                                Set it before the profile's first open in a run, or it applies at agweb's next start
  profile set <name> proxy off  no proxy
  profile delete <name>         delete a named profile and everything it stored
  passkey [list]                the passkeys agweb holds for this workspace's profile (in memory for a fresh one); a
                                site's passkey sign-up or sign-in in this workspace uses them with no prompt
  passkey delete <id>           forget one an agent made (the site still lists it until removed there)
  adblock [on|off|update]       ads and trackers are blocked with uBlock Origin's lists; off/on: for this workspace
                                only (Settings switches every workspace); pages opened directly always load
  unload [on|off]               off: this workspace's tabs are never unloaded (by default one unused 30 minutes,
                                per Settings, frees its memory and reloads when used), and its current tab keeps
                                running unseen while the window is open (by default 30 s after a command timers
                                slow to 1/s, then it freezes; a minimized, hidden or closed window pauses every page)
  sound [on|off]                on: this workspace's tabs are heard even while hidden or behind the dashboard (by
                                default muted unless shown); a playing tab one can hear is never unloaded
  install-cli [--check]         link /usr/local/bin/agweb to this app's CLI (also Help menu); --check says what is there
  install-skill [--check]       link the agent skill for Claude Code and Codex to this app's (also Help menu)
  update [--check]              install the latest release from GitHub and restart, every workspace reopening
                                (--check: only say whether one is out); agweb never updates by itself
  quit                          stop agweb
  version                       this agweb's version and the commit it was built from (also --version); put it in bug reports

--instant                       pointer verbs, scrolling, upload and type act at once instead of at human speed
--timeout=MS                    actions wait this long for their target to show (default 5000) and for anything covering it
                                to go (default 1000); 0: don't wait; wait: 30000
--filename=PATH                 snapshot, find, markdown, eval, request and response-body: write the answer to a file instead
--download-dir=DIR              where downloads nobody named go (default $AGWEB_DOWNLOAD_DIR, else .agweb/)
--raw                           print only the answer (eval's value, a snapshot), strings unquoted; events and notes go to stderr
--json                          print the reply as one JSON object
-w NAME, --workspace=NAME       default $AGWEB_WORKSPACE, else "default"
-p NAME, --profile=NAME         default $AGWEB_PROFILE, else a fresh profile
AGWEB_INSTANT=1                 every command as if --instant
`--` ends options, so text that starts with dashes can be passed: agweb type -- --verbose
env: AGWEB_ROOT=DIR runs a separate instance keeping everything in DIR; AGWEB_APP points at Agweb.app
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
let flags: Set = ["js", "help", "instant", "headed", "full-page", "full-resolution", "submit", "raw", "json", "static", "clear", "hide", "diff",
                  "httpOnly", "secure", "gone", "load", "single-page", "check", "all", "enabled", "version", "force"]
let valued: Set = ["profile", "workspace", "max-idle", "filename", "size", "filter", "status", "body", "content-type",
                   "header", "domain", "path", "expires", "sameSite", "style", "description", "duration", "browser", "text", "url",
                   "timeout", "color-scheme", "device", "format", "download-dir", "secret-cmd", "secret-file", "max-results", "camera", "mic", "accuracy",
                   "basic-auth"]
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

// eval's other name: some agent sandboxes refuse any shell command containing the word eval.
if positional.first == "js" { positional[0] = "eval" }
if positional.first == "tree" { positional[0] = "list" }
// The old names: profile-list, profile-delete.
for i in [0, 1] where positional.count > i && positional[i].hasPrefix("profile-") && (i == 0 || positional[0] == "help") {
    positional.insert(String(positional[i].dropFirst("profile-".count)), at: i + 1)
    positional[i] = "profile"
}
/// One command's lines of the usage: its own line and the indented lines continuing it.
func commandHelp(_ name: String) -> String? {
    var out: [String] = [], taking = false
    for line in usage.split(separator: "\n", omittingEmptySubsequences: false) {
        if line.hasPrefix("  "), line.dropFirst(2).first?.isLetter == true {
            // The command column runs to the first double space; "goto <url> | reload | go-back | go-forward" names
            // four, each the first word of its part, so "<text>" or "[target]" is never a name.
            let body = line.dropFirst(2)
            let column = body.range(of: "  ").map { body[..<$0.lowerBound] } ?? body
            let names = column.components(separatedBy: " | ").compactMap { $0.split(separator: " ").first.map(String.init) }
            taking = names.contains(name)
            if taking { out.append(String(line)) }
        } else if taking, line.hasPrefix("    ") {
            out.append(String(line))
        } else {
            taking = false
        }
    }
    return out.isEmpty ? nil : out.joined(separator: "\n")
}
if options["version"] != nil || positional.first == "version" {
    let info = appBundle().flatMap { NSDictionary(contentsOfFile: $0 + "/Contents/Info.plist") }
    let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
    print("agweb \(version)" + ((info?["AgwebCommit"] as? String).map { " (\($0))" } ?? ""))
    exit(0)
}
guard let command = positional.first, command != "help", options["help"] == nil else {
    // `help type` and `type --help` show that command; anything else the whole usage.
    let name = positional.first == "help" ? positional.dropFirst().first : positional.first
    print(name.flatMap(commandHelp).map { "agweb \(name!):\n\($0)\n\nTargets, options and the rest: agweb help" } ?? usage)
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
    if raw && ok { for note in Output.rawNotes(output) { FileHandle.standardError.write(Data("agweb: \(note)\n".utf8)) } }
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

let settingProxy = command == "profile" && args.first == "set" && args.count == 4 && args[2] == "proxy" && args[3] != "off"
let basicAuth = options["basic-auth"] != nil
if basicAuth, !["open", "goto"].contains(command) || args.isEmpty { fail("--basic-auth works with open <url> and goto <url>") }
if options["header"] != nil, command != "route", !["open", "goto"].contains(command) || args.isEmpty { fail("--header works with open <url>, goto <url> and route") }
if options["secret-cmd"] != nil || options["secret-file"] != nil {
    let command = options.removeValue(forKey: "secret-cmd"), file = options.removeValue(forKey: "secret-file")
    guard positional.first == "fill" || settingProxy || basicAuth else {
        fail("--secret-cmd and --secret-file work with fill, open/goto --basic-auth and profile set <name> proxy <url>")
    }
    guard command == nil || file == nil else { fail("use --secret-cmd or --secret-file, not both") }
    if settingProxy {
        options["proxy-password"] = secret(command: command, file: file)
    } else if basicAuth {
        options["basic-auth-password"] = secret(command: command, file: file)
        options["basic-auth-secret"] = ""
    } else {
        guard positional.count == 2 else { fail("use: agweb fill <target> --secret-cmd CMD | --secret-file PATH (no text)") }
        args.append(secret(command: command, file: file))
        options["secret"] = ""
    }
}
// --basic-auth USER:PASSWORD, or USER with the password from --secret-cmd/--secret-file.
if let auth = options["basic-auth"] {
    let user = String(auth.prefix { $0 != ":" }), inline = auth.contains(":") ? String(auth.drop { $0 != ":" }.dropFirst()) : nil
    guard !user.isEmpty else { fail("use: --basic-auth USER:PASSWORD, or --basic-auth USER --secret-cmd CMD") }
    guard (inline == nil) != (options["basic-auth-password"] == nil) else {
        fail(inline == nil ? "--basic-auth \(user) needs a password: USER:PASSWORD, --secret-cmd or --secret-file"
                           : "--basic-auth has a password and --secret-cmd/--secret-file gives another; use one")
    }
    options["basic-auth"] = user
    if let inline { options["basic-auth-password"] = inline }
}
// The password travels as an option, never in the arguments, which the app's command log keeps.
if settingProxy {
    var spec: ProxySpec
    do { spec = try ProxySpec.parse(args[3]) } catch { fail("\(error)") }
    if let inline = spec.password {
        guard options["proxy-password"] == nil else { fail("the proxy URL has a password and --secret-cmd/--secret-file gives another; use one") }
        options["proxy-password"] = inline
        spec.password = nil
    }
    spec.password = options["proxy-password"]
    do { try spec.validate() } catch { fail("\(error)") }
    spec.password = nil
    args[3] = spec.description
} else if command == "profile", args.contains(where: { $0.contains("://") && $0.contains("@") }) {
    // Mistyped: the app's reply or its command log would show the password.
    fail("use: agweb profile set <name> proxy <url> (the URL's password stays out of every reply)")
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
    // Before the chooser: WebKit takes a missing path as an empty file, and the page only refuses it much later.
    for file in args.dropFirst() where !FileManager.default.isReadableFile(atPath: file) { fail("no such file: \(file)") }
case "media":
    // The app reads only its own copy: opening the file where it is, in ~/Downloads say, would make macOS ask the person.
    if let file = args.first, file != "off" {
        options["file"] = file
        args = []
    }
    for kind in ["file", "camera", "mic"] {
        guard let given = options[kind].map(absolute) else { continue }
        // The file itself, not a link to it: the app would follow a copied link back into the person's folders.
        let path = URL(fileURLWithPath: given).resolvingSymlinksInPath().path
        guard FileManager.default.isReadableFile(atPath: path) else { fail("no such file: \(given)") }
        guard (try? FileManager.default.attributesOfItem(atPath: path)[.type] as? FileAttributeType) == .typeRegular else { fail("not a file: \(given)") }
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
        guard size <= 200 << 20 else { fail("\(path) is over 200 MB; a short clip is enough, it loops") }
        let folder = Agweb.root.appendingPathComponent("media/\(UUID().uuidString)")
        let copy = folder.appendingPathComponent((path as NSString).lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.copyItem(atPath: path, toPath: copy.path)
        } catch { fail("cannot copy \(path): \(error.localizedDescription)") }
        options[kind] = copy.path
    }
case "state-save":
    writeAnswerTo = writeAnswerTo ?? absolute(args.first ?? ".agweb/state-\(stamp).json")
    args = []
case "state-load":
    guard let file = writeAnswerTo ?? args.first.map(absolute) else { fail("missing <file>") }
    guard let data = FileManager.default.contents(atPath: file) else { fail("cannot read \(file)") }
    args = [String(decoding: data, as: UTF8.self)]
    writeAnswerTo = nil
case "snapshot" where writeAnswerTo != nil, "find" where writeAnswerTo != nil:
    // A file takes every line (and every match); the 2000-line cap is for what an agent reads.
    options["whole"] = ""
case "open", "goto", "tab-new":
    // A local file wins over a same-named host, the way a shell user would expect.
    if let target = args.first, FileManager.default.fileExists(atPath: absolute(target)) { args[0] = absolute(target) }
    // Where a URL that answers with a file is saved.
    if let path = writeAnswerTo { options["filename"] = path }
    writeAnswerTo = nil
default:
    break
}

/// Here, not in the app: it works before the CLI is on PATH and needs no running app.
if command == "install-cli" {
    guard let app = appBundle() else { fail("run the CLI inside the app: /Applications/Agweb.app/Contents/Helpers/agweb install-cli") }
    let helper = app + "/Contents/Helpers/agweb"
    if options["check"] != nil { finish(CLILink.status(helper: helper), ok: true) }
    let outcome = CLILink.install(helper: helper, bundle: app)
    let text = CLILink.describe(outcome, helper: helper)
    finish(outcome == .noPermission ? text + " Run it with sudo, or use Help ▸ Install Command Line Tool in agweb." : text, ok: outcome == .linked)
}

// Gone: a socket of its own still shared the person's profiles.
if env["AGWEB_SOCKET"] != nil { fail("AGWEB_SOCKET is gone; set AGWEB_ROOT=/tmp/some-dir instead, a folder for everything the instance keeps") }
if Agweb.isDefaultRoot, let app = appBundle(),
   let id = NSDictionary(contentsOfFile: app + "/Contents/Info.plist")?["CFBundleIdentifier"] as? String, Agweb.isTestBuild(id) {
    fail("this is a test build; set AGWEB_ROOT to a folder of its own, or it would drive the person's agweb")
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
        // -n with the root in its environment: an instance for exactly this root, whatever else runs.
        let launch = Process()
        launch.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        // The selftest's: a shorter visible time after a command, install targets away from the person's, a local filter list.
        let passed = ["AGWEB_AWAKE_SECONDS", "AGWEB_HOME", "AGWEB_CLI_LINK", "AGWEB_ADBLOCK_LISTS", "AGWEB_UPDATE_FEED", "AGWEB_PASSKEY_STORE", "AGWEB_PASSKEY_SECONDS", "AGWEB_UNLOAD_SECONDS"].flatMap { name in env[name].map { ["--env", "\(name)=\($0)"] } ?? [] }
        launch.arguments = ["-g", "-n", "--env", "AGWEB_ROOT=\(Agweb.root.path)"] + passed + ["-a", app]
        try launch.run()
        launch.waitUntilExit()
    }
    if !waitForSocket(15) { fail("agweb did not start listening on \(socket)") }
}

// Commands time out inside the app (pages 30 s, scripts 30 s, downloads 120 s, after the page's 30 s for a URL that
// answers with a file); this only catches a wedged app.
// Typing at a person's pace averages about 0.25 s a key, so long text gets longer.
// A wait gets its own timeout, or its fixed pause, plus room for the reply.
// wait, and actions waiting for their target, may take up to --timeout before they answer.
let waitSeconds = max(Int(options["timeout"] ?? "") ?? (command == "wait" ? 30_000 : command == "ask" ? 600_000 : 0), command == "wait" ? Int(args.first ?? "") ?? 0 : 0) / 1000 + 30
let timeout = max(["download", "goto", "open", "tab-new"].contains(command) ? 200 : 120, waitSeconds) + (command == "type" && options["instant"] == nil ? args.joined().count : 0)
guard let response = sendRequest(Request(workspace: workspace, command: command, args: args, options: options, timeout: timeout), path: socket, timeout: timeout) else {
    fail("no response from agweb on \(socket)")
}
guard response.ok, let path = writeAnswerTo else {
    finish(response.ok && command == "markdown" ? Output.capText(response.output) : response.output, ok: response.ok)
}

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
