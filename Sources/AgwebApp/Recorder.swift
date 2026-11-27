import AgwebCore
import AppKit
import AVFoundation
import WebKit

/// Records a workspace's current tab to MP4 at a steady 30 fps: a still page repeats its last picture, which H.264
/// stores in about 100 bytes, so tools that cut by time (ffmpeg's trim and -ss) find a frame at every instant; with
/// frames only at changes, a cut started at the next change and lost the time before it. While the agent is between commands,
/// only the first `maxIdle` seconds are kept: a blinking caret or a spinner changes pixels forever, so
/// pixel changes alone can't tell a page at rest. The pointer is drawn into the frames, never into the page.
@MainActor
final class Recorder {
    let url: URL
    private let workspace: Workspace
    private let size: CGSize
    private let maxIdle: Double
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var loop: Task<Void, Never>?
    /// Video time at `lastWall`, unrounded: rounding each step to the grid lost up to half a frame per tick.
    private var clock = 0.0
    /// The last 1/30 s slot written, and the one of the last new picture.
    private var slot = -1
    private var changedSlot = 0
    private var lastWall: Double?
    private var lastPixels: Data?
    private var lastPointer: CGPoint?
    private var lastHadRing = false
    /// The cursor the page shows under the pointer, and where and when it was asked last.
    private var cursor = Cursor.arrow
    private var lastCursor = Cursor.arrow
    private var cursorAsked: (point: CGPoint, time: Double, tab: Int)?
    private var askingCursor = false
    private var lastBuffer: CVPixelBuffer?
    /// Spans of `wait <ms>`: shown whole, never cut like idle time.
    private var holds: [ClosedRange<Double>] = []
    private var finished = false
    private var frames = 0
    private var lastBusy = ProcessInfo.processInfo.systemUptime
    /// Out of App Nap while recording: frames come from a 30 fps timer, between commands too.
    private var activity: NSObjectProtocol?

    /// `frameSize` defaults to the viewport; another size letterboxes it.
    init(workspace: Workspace, url: URL, maxIdle: Double, frameSize: CGSize? = nil) throws {
        guard let tab = workspace.current else { throw Failure("nothing to record: the workspace has no tabs") }
        guard let rect = Self.viewport(of: tab.webView) else {
            throw Failure(tab.webView.window.map(MainWindow.notRendering) ?? "the tab is not in the window")
        }
        guard url.pathExtension.lowercased() == "mp4" else { throw Failure("the video path must end in .mp4: \(url.path)") }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            throw Failure("\(url.path) is a directory")
        }
        // H.264 needs even dimensions. One pixel per point keeps files small and pages readable.
        let wanted = frameSize ?? rect.size
        size = CGSize(width: Int(wanted.width) & ~1, height: Int(wanted.height) & ~1)
        self.workspace = workspace
        self.url = url
        self.maxIdle = maxIdle
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        // The index first, so a browser starts playing before the whole file is down.
        writer.shouldOptimizeForNetworkUse = true
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: size.width, AVVideoHeightKey: size.height,
            // Quality 0.5 keeps text as sharp as the default at about a quarter of the size, and a repeated frame
            // nearly free. Keyframes every 10 s, not every 30 frames: at 1080p each costs about 100 KB.
            AVVideoCompressionPropertiesKey: [AVVideoQualityKey: 0.5, AVVideoMaxKeyFrameIntervalDurationKey: 10, AVVideoMaxKeyFrameIntervalKey: 300],
        ])
        // Frames are pushed when they exist, not paced by a capture device.
        input.expectsMediaDataInRealTime = false
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: size.width, kCVPixelBufferHeightKey as String: size.height,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? Failure("could not start writing \(url.path)") }
        writer.startSession(atSourceTime: .zero)
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical], reason: "recording a video")
        loop = Task { @MainActor [weak self] in
            while !Task.isCancelled, let self {
                let began = ProcessInfo.processInfo.systemUptime
                await self.capture()
                let spent = ProcessInfo.processInfo.systemUptime - began
                try? await Task.sleep(for: .seconds(max(0.005, 1.0 / 30 - spent)))
            }
        }
    }

    /// Finishes the file and describes it.
    func stop() async throws -> String {
        // Stopped (or quit) right after starting: take the first frame now rather than throw the file away. A tab
        // just woken from hidden can give an empty snapshot for a moment, so try for up to a second.
        for _ in 0..<10 where frames == 0 {
            await capture()
            if frames == 0 { try? await Task.sleep(for: .milliseconds(100)) }
        }
        // A click's capture may be awaiting a snapshot; appending after markAsFinished would raise.
        finished = true
        loop?.cancel()
        await loop?.value
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        guard frames > 0 else {
            writer.cancelWriting()
            throw Failure("no frames were recorded; is the window closed, minimized or hidden?")
        }
        guard writer.status == .writing else { throw writer.error ?? Failure("recording to \(url.path) failed") }
        // The last picture stays until the stop, cut like any idle time, and for at least a second.
        let now = ProcessInfo.processInfo.systemUptime
        let end = max(time(at: now, idleShown: max(0, (lastWall ?? now) - lastBusy)), Double(changedSlot) / 30 + 1)
        let endSlot = max(slot, min(Int((end * 30).rounded()), slot + Self.longestGap))
        if let lastBuffer {
            while slot < endSlot {
                for _ in 0..<500 where !input.isReadyForMoreMediaData { try? await Task.sleep(for: .milliseconds(10)) }
                guard input.isReadyForMoreMediaData, adaptor.append(lastBuffer, withPresentationTime: Self.at(slot + 1)) else { break }
                slot += 1
                frames += 1
            }
        }
        input.markAsFinished()
        let length = Double(slot + 1) / 30
        writer.endSession(atSourceTime: Self.at(slot + 1))
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? Failure("could not finish \(url.path)") }
        return "### Video\n\(url.path)\n- \(frames) frames, \(String(format: "%.1f", length)) s, \(Int(size.width))x\(Int(size.height))"
    }

    /// Also called by a click while the button is down, so the pressed state makes it into the video.
    func capture(timeout: Double = 5) async {
        let now = ProcessInfo.processInfo.systemUptime
        // Idle time already in the video, so a pause never shows for more than maxIdle in total.
        let idleShown = max(0, (lastWall ?? now) - lastBusy)
        if workspace.busy { lastBusy = now } else if maxIdle > 0, now - lastBusy > maxIdle { return }
        guard !finished, let tab = workspace.current, let rect = Self.viewport(of: tab.webView),
              let image = await snapshot(tab, rect, timeout: timeout), !finished else { return }
        var ring: Double?
        if let click = tab.lastClick, ProcessInfo.processInfo.systemUptime - click.time < Self.ringSeconds {
            ring = ProcessInfo.processInfo.systemUptime - click.time
        }
        askCursor(tab)
        // A moving pointer, a new cursor or a ring means a new frame anyway; skip the bitmap copy then, it slows glides.
        let moved = tab.pointer != lastPointer || cursor != lastCursor || ring != nil || lastHadRing
        let pixels = moved ? nil : image.dataProvider?.data as Data?
        let changed = moved || pixels == nil || pixels != lastPixels
        let wall = ProcessInfo.processInfo.systemUptime
        let time = lastWall == nil ? 0 : self.time(at: wall, idleShown: idleShown)
        // A new picture takes the next free slot even when it comes early (a click's own capture); the clock stays
        // unrounded, so the slots catch up with it.
        // A stretch with no pictures at all (the window hidden, snapshots timing out) shows at most 10 s of the last one.
        let due = min(Int((time * 30).rounded()), slot + Self.longestGap), target = changed ? max(slot + 1, due) : due
        // The clock keeps the time to the millisecond, cut only by that cap: rounded to a slot, each tick (a little over
        // 1/30 s) lost its extra, and videos ran 4% short of real time.
        let next = min(time, Double(slot + Self.longestGap) / 30)
        // The slots since the last tick repeat the last picture. A writer that can't keep up stops the fill here; the
        // next tick goes on from where it stopped.
        if let lastBuffer {
            while slot + 1 < target || (!changed && slot < target) {
                guard input.isReadyForMoreMediaData, adaptor.append(lastBuffer, withPresentationTime: Self.at(slot + 1)) else {
                    if writer.status == .failed { loop?.cancel() }
                    return
                }
                slot += 1
                frames += 1
            }
        }
        guard changed else {
            clock = next
            lastWall = wall
            return
        }
        guard input.isReadyForMoreMediaData, let buffer = draw(image, from: rect, pointer: tab.pointer,
                                                               scale: tab.webView.pageZoom * tab.webView.magnification,
                                                               click: tab.lastClick?.point, ring: ring) else { return }
        guard adaptor.append(buffer, withPresentationTime: Self.at(target)) else {
            if writer.status == .failed { loop?.cancel() }
            return
        }
        slot = target
        changedSlot = target
        clock = next
        lastWall = wall
        lastBuffer = buffer
        lastPixels = pixels
        lastPointer = tab.pointer
        lastCursor = cursor
        lastHadRing = ring != nil
        frames += 1
    }

    /// An explicit wait of `seconds` from now: the viewer gets all of it, even on a still page.
    func hold(_ seconds: Double) {
        let now = ProcessInfo.processInfo.systemUptime
        holds = holds.filter { $0.upperBound > (lastWall ?? now) } + [now...(now + seconds)]
    }

    /// Where a frame seen at `wall` goes in the video: the gap since the last frame, with idle time cut to maxIdle
    /// but the part spent in a `wait <ms>` kept whole.
    private func time(at wall: Double, idleShown: Double) -> Double {
        guard let lastWall else { return clock }
        let gap = wall - lastWall
        let held = min(gap, holds.reduce(0) { $0 + max(0, min(wall, $1.upperBound) - max(lastWall, $1.lowerBound)) })
        let rest = gap - held
        return clock + held + (maxIdle > 0 ? min(rest, max(0, maxIdle - idleShown)) : rest)
    }

    private static let longestGap = 300

    /// A slot's time: frames on a 1/30 s grid.
    private static func at(_ slot: Int) -> CMTime { CMTime(value: CMTimeValue(slot) * 20, timescale: 600) }

    /// The page's viewport: the web view minus the toolbar band a full-size content view puts over it.
    /// Snapshot rects start at the top of the page, below that band, so only the height changes.
    private static func viewport(of webView: WKWebView) -> CGRect? {
        guard let window = webView.window, MainWindow.isRendering(window) else { return nil }
        let inWindow = webView.convert(webView.bounds, to: nil)
        let inset = max(0, inWindow.maxY - window.contentLayoutRect.maxY)
        let height = webView.bounds.height - inset
        guard height > 0, webView.bounds.width > 0 else { return nil }
        return CGRect(x: 0, y: 0, width: webView.bounds.width, height: height)
    }

    private func snapshot(_ tab: Tab, _ rect: CGRect, timeout: Double) async -> CGImage? {
        let config = WKSnapshotConfiguration()
        config.rect = rect
        config.snapshotWidth = NSNumber(value: rect.width * fit(rect).scale / (tab.webView.window?.backingScaleFactor ?? 1))
        return try? await tab.snapshot(config, timeout: timeout).cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    private static let ringSeconds = 0.42

    /// Where a viewport of this size lands in the fixed frame: scaled to fit and centred, so a window resized
    /// mid-recording is letterboxed rather than stretched.
    private func fit(_ rect: CGRect) -> (scale: CGFloat, frame: CGRect) {
        // The frame is the viewport rounded down to even pixels; resampling for that fraction only blurs text.
        if abs(rect.width - size.width) < 2, abs(rect.height - size.height) < 2 { return (1, CGRect(origin: .zero, size: size)) }
        let scale = min(size.width / rect.width, size.height / rect.height)
        let fitted = CGSize(width: rect.width * scale, height: rect.height * scale)
        return (scale, CGRect(x: (size.width - fitted.width) / 2, y: (size.height - fitted.height) / 2, width: fitted.width, height: fitted.height))
    }

    private func draw(_ image: CGImage, from rect: CGRect, pointer: CGPoint?, scale: CGFloat, click: CGPoint?, ring: Double?) -> CVPixelBuffer? {
        guard let pool = adaptor.pixelBufferPool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        let (fitScale, frame) = fit(rect)
        context.interpolationQuality = fitScale == 1 ? .none : .high
        if frame.size != size { context.clear(CGRect(origin: .zero, size: size)) }
        context.draw(image, in: frame)
        // CSS pixels from the viewport's top left, to this context's bottom-left pixels.
        func flip(_ p: CGPoint) -> CGPoint { CGPoint(x: frame.minX + p.x * scale * fitScale, y: frame.maxY - p.y * scale * fitScale) }
        if let click, let ring {
            let u = ring / Self.ringSeconds, center = flip(click), radius = 24 * u
            let circle = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            context.setFillColor(red: 0, green: 0.47, blue: 1, alpha: 0.32 * (1 - u))
            context.fillEllipse(in: circle)
            context.setStrokeColor(red: 0, green: 0.47, blue: 1, alpha: 0.9 * (1 - u))
            context.setLineWidth(2)
            context.strokeEllipse(in: circle)
        }
        if let pointer {
            switch cursor {
            case .arrow: Self.drawArrow(context, at: flip(pointer))
            case .hand: Self.draw(NSCursor.pointingHand, context, at: flip(pointer))
            case .text: Self.draw(NSCursor.iBeam, context, at: flip(pointer))
            }
        }
        return buffer
    }

    enum Cursor: String { case arrow, hand, text }

    /// Asked when the pointer moves, and twice a second while it rests (the page can change under it: a click that
    /// opens a menu, a link that loads). Never awaited: a page that is loading or busy would stall the frames, so the
    /// answer shows from the next tick on.
    private func askCursor(_ tab: Tab) {
        guard let pointer = tab.pointer else { cursor = .arrow; return }
        let now = ProcessInfo.processInfo.systemUptime
        if let asked = cursorAsked, asked.point == pointer, asked.tab == tab.id, now - asked.time < 0.5 { return }
        guard !askingCursor else { return }
        askingCursor = true
        Task { [weak self] in
            let answer = try? await tab.call(PageScripts.cursorAt, ["x": pointer.x, "y": pointer.y], timeout: 1)
            guard let self else { return }
            self.askingCursor = false
            // A page that can't answer (loading, an alert open) is asked again in half a second, not every tick.
            self.cursorAsked = (pointer, ProcessInfo.processInfo.systemUptime, tab.id)
            if let answer { self.cursor = Cursor(rawValue: answer) ?? .arrow }
        }
    }

    /// macOS's own cursor, its hotspot on the pointer, at its size on screen.
    private static func draw(_ cursor: NSCursor, _ context: CGContext, at point: CGPoint) {
        let size = cursor.image.size, hot = cursor.hotSpot
        context.interpolationQuality = .high
        var rect = CGRect(origin: .zero, size: size)
        guard let image = cursor.image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return }
        context.draw(image, in: CGRect(x: point.x - hot.x, y: point.y - (size.height - hot.y), width: size.width, height: size.height))
    }

    /// The qa-video skill's arrow: tip at the hotspot, black with a white rim and a soft shadow.
    private static func drawArrow(_ context: CGContext, at tip: CGPoint) {
        let outline: [(CGFloat, CGFloat)] = [(2, 1.5), (2, 21), (7, 16), (10.5, 24), (14, 22.5), (10.6, 15), (17.5, 15)]
        let path = CGMutablePath()
        path.addLines(between: outline.map { CGPoint(x: tip.x + $0.0 - 2, y: tip.y - ($0.1 - 1.5)) })
        path.closeSubpath()
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -1), blur: 2, color: CGColor(gray: 0, alpha: 0.4))
        context.addPath(path)
        context.setFillColor(gray: 0.07, alpha: 1)
        context.fillPath()
        context.restoreGState()
        context.addPath(path)
        context.setStrokeColor(gray: 1, alpha: 1)
        context.setLineWidth(1.6)
        context.setLineJoin(.round)
        context.strokePath()
    }
}
