import CoreGraphics
import Foundation

/// Human pointer paths and typing rhythm, ported from the qa-video skill's prelude.js: Fitts's-law duration,
/// a bowed cubic Bezier at minimum-jerk speed, a corrective second leg on long throws, off-centre aim.
/// Its tremor is left out: a pixel of wobble is invisible and only adds events.
public struct Motion {
    public typealias Step = (point: CGPoint, pause: Double)

    private var state: UInt64

    /// A fixed seed repeats the same paths and delays; tests use it.
    public init(seed: UInt64 = .random(in: 0...UInt64.max)) { state = seed }

    /// SplitMix64, uniform in [0, 1).
    public mutating func random() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Double((z ^ (z >> 31)) >> 11) / Double(UInt64(1) << 53)
    }

    public mutating func jitter(_ base: Double, _ spread: Double) -> Double { base + (random() - 0.5) * 2 * spread }

    public mutating func aim(center: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(x: center.x + jitter(0, min(size.width * 0.18, 9)), y: center.y + jitter(0, min(size.height * 0.18, 5)))
    }

    /// Points about 60 Hz apart, each with the pause that follows it; the last point is `to`.
    public mutating func path(from: CGPoint, to: CGPoint, targetSize: Double) -> [Step] {
        let dist = hypot(to.x - from.x, to.y - from.y)
        guard dist >= 0.5 else { return [(to, 0)] }
        let index = log2(2 * dist / min(max(targetSize, 14), 320) + 1)
        let seconds = min(max(0.115 + 0.135 * index, 0.2), 1.15)
        guard dist > 260 else { return leg(from, to, seconds) }
        // A ballistic throw that falls short, then a quick correction.
        let f = 0.88 + 0.07 * random()
        let short = CGPoint(x: from.x + (to.x - from.x) * f + jitter(0, dist * 0.012),
                            y: from.y + (to.y - from.y) * f + jitter(0, dist * 0.012))
        var throwLeg = leg(from, short, seconds * 0.8)
        throwLeg[throwLeg.count - 1].pause = jitter(0.038, 0.014)
        return throwLeg + leg(short, to, min(max(seconds * 0.3, 0.11), 0.24))
    }

    private mutating func leg(_ a: CGPoint, _ b: CGPoint, _ seconds: Double) -> [Step] {
        let dx = b.x - a.x, dy = b.y - a.y, dist = hypot(dx, dy)
        guard dist >= 0.5 else { return [(b, 0)] }
        let bow = dist * 0.055 * (0.55 + 0.9 * random()) * (random() < 0.5 ? -1 : 1)
        let nx = -dy / dist * bow, ny = dx / dist * bow
        let p1 = CGPoint(x: a.x + dx * 0.33 + nx, y: a.y + dy * 0.33 + ny)
        let p2 = CGPoint(x: a.x + dx * 0.66 + nx * 0.55, y: a.y + dy * 0.66 + ny * 0.55)
        let tick = 1.0 / 60
        let count = max(1, Int((seconds / tick).rounded()))
        return (1...count).map { i in
            let u = Double(i) / Double(count)
            let e = u * u * u * (10 + u * (-15 + 6 * u))
            let m = 1 - e
            let (c0, c1, c2, c3) = (m * m * m, 3 * m * m * e, 3 * m * e * e, e * e * e)
            return (CGPoint(x: c0 * a.x + c1 * p1.x + c2 * p2.x + c3 * b.x, y: c0 * a.y + c1 * p1.y + c2 * p2.y + c3 * b.y), tick)
        }
    }

    /// Seconds to wait after typing `char`: longer after spaces and punctuation, and now and then a hesitation.
    public mutating func keyDelay(after char: Character) -> Double {
        var delay = jitter(0.165, 0.065)
        if char == " " {
            delay += jitter(0.09, 0.04)
        } else if ".,@!?:;_-/".contains(char) {
            delay += jitter(0.18, 0.07)
        }
        if random() < 0.07 { delay += jitter(0.42, 0.16) }
        return delay
    }
}
