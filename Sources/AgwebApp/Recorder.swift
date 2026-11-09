import AppKit
import AVFoundation
import WebKit

/// Records a session's current tab to MP4. Frames are written only when the page, the pointer or a click
/// ring changed, each at its own time, so a still page costs nothing. While the agent is between commands,
/// only the first `maxIdle` seconds are kept: a blinking caret or a spinner changes pixels forever, so
/// pixel changes alone can't tell a page at rest. The pointer is drawn into the frames, never into the page.
@MainActor
final class Recorder {
    let url: URL
    private let session: Session
    private let size: CGSize
    private let maxIdle: Double
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var loop: Task<Void, Never>?
    private var clock = 0.0
    private var lastWall: Double?
    private var lastPixels: Data?
    private var lastPointer: CGPoint?
    private var frames = 0
    private var lastBusy = ProcessInfo.processInfo.systemUptime

    init(session: Session, url: URL, maxIdle: Double) throws {
        guard let tab = session.current, let rect = Self.viewport(of: tab.webView) else {
            throw Failure("nothing to record: the session has no tab in the window")
        }
        // H.264 needs even dimensions. One pixel per point keeps files small and pages readable.
        size = CGSize(width: Int(rect.width) & ~1, height: Int(rect.height) & ~1)
        self.session = session
        self.url = url
        self.maxIdle = maxIdle
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: size.width, AVVideoHeightKey: size.height,
        ])
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: size.width, kCVPixelBufferHeightKey as String: size.height,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? Failure("could not start writing \(url.path)") }
        writer.startSession(atSourceTime: .zero)
    }

    func start() {
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
        loop?.cancel()
        await loop?.value
        guard frames > 0 else {
            writer.cancelWriting()
            throw Failure("no frames were recorded; is the window closed? (agweb show)")
        }
        input.markAsFinished()
        // The last frame holds for a second instead of ending the video the moment it appears.
        writer.endSession(atSourceTime: CMTime(seconds: clock + 1, preferredTimescale: 600))
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? Failure("could not finish \(url.path)") }
        return "### Video\n\(url.path)\n- \(frames) frames, \(String(format: "%.1f", clock + 1)) s, \(Int(size.width))x\(Int(size.height))"
    }

    /// Also called by a click while the button is down, so the pressed state makes it into the video.
    func capture() async {
        let now = ProcessInfo.processInfo.systemUptime
        if session.busy { lastBusy = now } else if maxIdle > 0, now - lastBusy > maxIdle { return }
        guard let tab = session.current, let rect = Self.viewport(of: tab.webView), let image = await snapshot(tab.webView, rect) else { return }
        let pixels = image.dataProvider?.data as Data?
        let ring = tab.lastClick.map { ProcessInfo.processInfo.systemUptime - $0.time }.flatMap { $0 < Self.ringSeconds ? $0 : nil }
        if pixels == lastPixels, tab.pointer == lastPointer, ring == nil { return }
        let wall = ProcessInfo.processInfo.systemUptime
        if let lastWall {
            let gap = wall - lastWall
            clock += maxIdle > 0 ? min(gap, maxIdle) : gap
        }
        guard input.isReadyForMoreMediaData, let buffer = draw(image, pointer: tab.pointer, scale: tab.webView.pageZoom * tab.webView.magnification,
                                                               click: tab.lastClick?.point, ring: ring) else { return }
        guard adaptor.append(buffer, withPresentationTime: CMTime(seconds: clock, preferredTimescale: 600)) else { return }
        lastWall = wall
        lastPixels = pixels
        lastPointer = tab.pointer
        frames += 1
        // Two frames inside one timescale tick would collide.
        clock += 1.0 / 600
    }

    /// The page's viewport: the web view minus the toolbar band a full-size content view puts over it.
    /// Snapshot rects start at the top of the page, below that band, so only the height changes.
    private static func viewport(of webView: WKWebView) -> CGRect? {
        guard let window = webView.window, window.isVisible, !window.isMiniaturized else { return nil }
        let inWindow = webView.convert(webView.bounds, to: nil)
        let inset = max(0, inWindow.maxY - window.contentLayoutRect.maxY)
        let height = webView.bounds.height - inset
        guard height > 0, webView.bounds.width > 0 else { return nil }
        return CGRect(x: 0, y: 0, width: webView.bounds.width, height: height)
    }

    private func snapshot(_ webView: WKWebView, _ rect: CGRect) async -> CGImage? {
        let config = WKSnapshotConfiguration()
        config.rect = rect
        config.snapshotWidth = NSNumber(value: size.width / (webView.window?.backingScaleFactor ?? 1))
        let image = try? await withTimeout(5, "video frame") {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NSImage, Error>) in
                webView.takeSnapshot(with: config) { image, error in
                    if let image { continuation.resume(returning: image) } else { continuation.resume(throwing: error ?? Failure("snapshot failed")) }
                }
            }
        }
        return image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    private static let ringSeconds = 0.42

    private func draw(_ image: CGImage, pointer: CGPoint?, scale: CGFloat, click: CGPoint?, ring: Double?) -> CVPixelBuffer? {
        guard let pool = adaptor.pixelBufferPool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: size))
        // CSS pixels from the viewport's top left, to this context's bottom-left points.
        func flip(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * scale, y: size.height - p.y * scale) }
        if let click, let ring {
            let u = ring / Self.ringSeconds, center = flip(click), radius = 24 * u
            let circle = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            context.setFillColor(red: 0, green: 0.47, blue: 1, alpha: 0.32 * (1 - u))
            context.fillEllipse(in: circle)
            context.setStrokeColor(red: 0, green: 0.47, blue: 1, alpha: 0.9 * (1 - u))
            context.setLineWidth(2)
            context.strokeEllipse(in: circle)
        }
        if let pointer { Self.drawArrow(context, at: flip(pointer)) }
        return buffer
    }

    /// The qa-video skill's arrow: tip at the hotspot, black with a white rim and a soft shadow.
    private static func drawArrow(_ context: CGContext, at tip: CGPoint) {
        let points: [CGPoint] = [(2, 1.5), (2, 21), (7, 16), (10.5, 24), (14, 22.5), (10.6, 15), (17.5, 15)].map { CGPoint(x: $0.0, y: $0.1) }
        let path = CGMutablePath()
        path.addLines(between: points.map { CGPoint(x: tip.x + $0.x - 2, y: tip.y - ($0.y - 1.5)) })
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
