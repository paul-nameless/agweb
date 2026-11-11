import Darwin
import Foundation

public struct Request: Codable, Sendable {
    public var workspace: String
    public var command: String
    public var args: [String]
    public var options: [String: String]

    public init(workspace: String, command: String, args: [String], options: [String: String]) {
        self.workspace = workspace
        self.command = command
        self.args = args
        self.options = options
    }
}

public struct Response: Codable, Sendable {
    public var ok: Bool
    public var output: String

    public init(ok: Bool, output: String) {
        self.ok = ok
        self.output = output
    }
}

public enum Agweb {
    /// A test build carries its own (`build.sh --test`), so macOS keeps its settings and privacy grants apart.
    public static let bundleIdentifier = Bundle.main.bundleIdentifier ?? "dev.playground.agweb"

    /// Everything an instance keeps: socket, workspaces, profiles, logs and, for any root but the default, the profiles'
    /// WebKit data and settings. AGWEB_ROOT=/tmp/x runs a second instance that shares nothing with the person's.
    public static func resolveRoot(_ value: String?, home: URL) -> (root: URL, isDefault: Bool) {
        let defaultRoot = home.appendingPathComponent("Library/Application Support/agweb").standardizedFileURL
        guard let value, !value.isEmpty else { return (defaultRoot, true) }
        // Kept as given, so the CLI, the app and scripts name it alike; symlinks matter only for spotting the default.
        let root = URL(fileURLWithPath: value).standardizedFileURL
        return (root, root.resolvingSymlinksInPath().path == defaultRoot.resolvingSymlinksInPath().path)
    }

    private static let resolved = resolveRoot(ProcessInfo.processInfo.environment["AGWEB_ROOT"], home: FileManager.default.homeDirectoryForCurrentUser)
    public static var root: URL { resolved.root }
    /// The person's instance; any other root is a test or a debugging copy.
    public static var isDefaultRoot: Bool { resolved.isDefault }
    /// `build.sh --test`; it runs only on a root of its own, so a forgotten AGWEB_ROOT can't take over the person's.
    public static func isTestBuild(_ bundleIdentifier: String) -> Bool { bundleIdentifier.hasSuffix(".test") }
    /// Settings and the window frame of a non-default root, a defaults domain of its own.
    public static func settingsSuite(root: URL) -> String { "agweb.root" + root.path.replacingOccurrences(of: "/", with: "_") }

    public static var socketPath: String { root.appendingPathComponent("agweb.sock").path }
    public static var workspacesFile: URL { root.appendingPathComponent("workspaces.json") }
    public static var profilesFolder: URL { root.appendingPathComponent("profiles") }
    public static var logsFolder: URL { root.appendingPathComponent("logs") }
    /// Shown on a non-default instance's Dock icon and sidebar, so its window can't be taken for the person's.
    public static var label: String? { isDefaultRoot ? nil : root.lastPathComponent }

    /// Held by the instance that owns a socket for as long as it runs. A free lock means nobody is serving or
    /// starting up there; a held one means wait. One `open` per socket, and test instances never block the default.
    public static func lockOwnership(of socket: String) -> Int32? {
        try? FileManager.default.createDirectory(atPath: (socket as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let fd = open(socket + ".lock", O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return nil }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { return fd }
        close(fd)
        return nil
    }
}

public struct Failure: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

// Plain AF_UNIX sockets: one JSON request line in, one JSON response out, then close.

private func unixAddress(_ path: String) throws -> sockaddr_un {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    let capacity = MemoryLayout.size(ofValue: addr.sun_path)
    // A silently truncated path would bind one file and unlink another.
    guard bytes.count < capacity else { throw Failure("socket path is longer than \(capacity - 1) bytes: \(path); choose a shorter AGWEB_ROOT") }
    withUnsafeMutableBytes(of: &addr.sun_path) { buf in
        buf.copyBytes(from: bytes)
        buf[bytes.count] = 0
    }
    return addr
}

private func withSockaddr<T>(_ addr: inout sockaddr_un, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
    withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
}

private func setOption<T>(_ fd: Int32, _ name: Int32, _ value: T) {
    _ = withUnsafeBytes(of: value) { setsockopt(fd, SOL_SOCKET, name, $0.baseAddress, socklen_t($0.count)) }
}

private func setTimeouts(_ fd: Int32, seconds: Int) {
    let tv = timeval(tv_sec: seconds, tv_usec: 0)
    setOption(fd, SO_RCVTIMEO, tv)
    setOption(fd, SO_SNDTIMEO, tv)
}

public func connectSocket(_ path: String) -> Int32? {
    guard var addr = try? unixAddress(path) else { return nil }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    setOption(fd, SO_NOSIGPIPE, Int32(1))
    if withSockaddr(&addr, { connect(fd, $0, $1) }) != 0 {
        close(fd)
        return nil
    }
    return fd
}

public func isServing(_ path: String) -> Bool {
    guard let fd = connectSocket(path) else { return false }
    close(fd)
    return true
}

public func readAll(_ fd: Int32, untilNewline: Bool) -> Data {
    var data = Data()
    var buf = [UInt8](repeating: 0, count: 65536)
    while true {
        let n = read(fd, &buf, buf.count)
        if n <= 0 { break }
        data.append(buf, count: n)
        if untilNewline, buf[..<n].contains(10) { break }
    }
    return data
}

public func writeAll(_ fd: Int32, _ data: Data) {
    data.withUnsafeBytes { raw in
        var offset = 0
        while offset < raw.count {
            let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
            if n <= 0 { return }
            offset += n
        }
    }
}

/// Returns nil when the app can't be reached or did not answer within `timeout` seconds.
public func sendRequest(_ request: Request, path: String, timeout: Int) -> Response? {
    guard let fd = connectSocket(path) else { return nil }
    defer { close(fd) }
    setTimeouts(fd, seconds: timeout)
    guard var line = try? JSONEncoder().encode(request) else { return nil }
    line.append(10)
    writeAll(fd, line)
    return try? JSONDecoder().decode(Response.self, from: readAll(fd, untilNewline: false))
}

/// Answers each connection on `path` with `handler`, on a background thread, for the life of the process.
public func serve(path: String, handler: @escaping @Sendable (Request) async -> Response) throws {
    var addr = try unixAddress(path)
    try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    unlink(path)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    // The socket file is created by bind; a umask keeps it private from the first instant.
    let previousMask = umask(0o177)
    let bound = fd >= 0 && withSockaddr(&addr, { bind(fd, $0, $1) }) == 0
    umask(previousMask)
    guard bound, listen(fd, 64) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    Thread.detachNewThread {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                usleep(10_000)  // EMFILE and friends: back off instead of spinning
                continue
            }
            setOption(client, SO_NOSIGPIPE, Int32(1))
            // A client that connects and never finishes its line must not block the others.
            setTimeouts(client, seconds: 10)
            DispatchQueue.global().async {
                let data = readAll(client, untilNewline: true)
                Task {
                    let response: Response
                    if let request = try? JSONDecoder().decode(Request.self, from: data) {
                        response = await handler(request)
                    } else {
                        response = Response(ok: false, output: "malformed request")
                    }
                    setTimeouts(client, seconds: 30)
                    writeAll(client, (try? JSONEncoder().encode(response)) ?? Data())
                    close(client)
                }
            }
        }
    }
}
