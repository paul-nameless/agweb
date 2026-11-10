import CoreGraphics
import Foundation

/// Human pointer paths and typing rhythm, from the qa-video skill's prelude.js and the HCI literature: Fitts's-law
/// duration, a bowed cubic Bezier whose speed peaks early, a slight hand wobble (bot checks flag mathematically
/// smooth curves), a corrective second leg on long throws, aim scattered around the target's middle.
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

    /// Standard normal, by Box-Muller.
    public mutating func gaussian() -> Double {
        sqrt(-2 * log(max(random(), 1e-12))) * cos(2 * .pi * random())
    }

    /// Log-normal with this median: mostly near it, now and then much longer, as human timings are.
    public mutating func logNormal(median: Double, sigma: Double) -> Double { median * exp(sigma * gaussian()) }

    /// Where a person lands on a target: normally scattered around its middle (SD a sixth of its size, Meyer
    /// 1988), never outside it.
    public mutating func aim(center: CGPoint, size: CGSize) -> CGPoint {
        func axis(_ side: Double) -> Double { min(max(side / 6 * gaussian(), -side * 0.4), side * 0.4) }
        return CGPoint(x: center.x + axis(size.width), y: center.y + axis(size.height))
    }

    /// Points about 60 Hz apart, each with the pause that follows it; the last point is `to`.
    public mutating func path(from: CGPoint, to: CGPoint, targetSize: Double) -> [Step] {
        let dist = hypot(to.x - from.x, to.y - from.y)
        guard dist >= 0.5 else { return [(to, 0)] }
        let index = log2(2 * dist / min(max(targetSize, 14), 320) + 1)
        let seconds = min(max(0.115 + 0.135 * index, 0.2), 1.15)
        // The harder the target, the likelier a ballistic throw that misses, then a quick correction; most throws
        // fall short, some overshoot.
        guard random() < min(max((index - 2.5) / 3, 0), 0.9) else { return leg(from, to, seconds) }
        let f = random() < 0.3 ? 1.03 + 0.05 * random() : 0.88 + 0.07 * random()
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
        // A wobble of about a pixel, smooth and gone at both ends, so the leg still lands exactly.
        let wobble = (x: 0.5 + random(), y: 0.5 + random(), fx: 1.5 + 1.5 * random(), fy: 1.5 + 1.5 * random(),
                      px: 2 * .pi * random(), py: 2 * .pi * random())
        return (1...count).map { i in
            if i == count { return (b, tick) }
            let u = Double(i) / Double(count)
            // Minimum jerk on warped time: the speed peaks at 40% of the way, not halfway, and the hand slows into
            // the target, as aimed movements do.
            let w = pow(u, 0.756)
            let e = w * w * w * (10 + w * (-15 + 6 * w))
            let m = 1 - e
            let (c0, c1, c2, c3) = (m * m * m, 3 * m * m * e, 3 * m * e * e, e * e * e)
            let fade = sin(.pi * u)
            return (CGPoint(x: c0 * a.x + c1 * p1.x + c2 * p2.x + c3 * b.x + wobble.x * fade * sin(2 * .pi * wobble.fx * u + wobble.px),
                            y: c0 * a.y + c1 * p1.y + c2 * p2.y + c3 * b.y + wobble.y * fade * sin(2 * .pi * wobble.fy * u + wobble.py)), tick)
        }
    }

    /// Seconds from pressing `char` to pressing `next`, as measured in 136M keystrokes (Dhakal et al., CHI 2018):
    /// log-normal around 0.22 s with a long tail, longer after spaces and punctuation, a little shorter when the
    /// hands alternate, and now and then a hesitation.
    public mutating func keyDelay(after char: Character, next: Character? = nil) -> Double {
        var delay = logNormal(median: 0.2, sigma: 0.42)
        if char == " " {
            delay += jitter(0.06, 0.03)
        } else if ".,@!?:;_-/".contains(char) {
            delay += jitter(0.14, 0.06)
        }
        if let next, let a = Self.hand(char), let b = Self.hand(next) { delay += a == b ? 0.01 : -0.015 }
        if random() < 0.05 { delay += logNormal(median: 0.4, sigma: 0.35) }
        return min(max(delay, 0.06), 2)
    }

    /// The pause between the pointer stopping and the button going down: usually short, now and then a long look.
    public mutating func dwell() -> Double { min(max(logNormal(median: 0.16, sigma: 0.6), 0.04), 1) }

    /// Where a pointer first appears: just inside an edge, as if the hand came in from outside the window.
    public mutating func entry(viewport: CGSize) -> CGPoint {
        let along = 0.15 + 0.7 * random()
        switch Int(random() * 3) {
        case 0: return CGPoint(x: viewport.width * along, y: viewport.height - 2)
        case 1: return CGPoint(x: viewport.width - 2, y: viewport.height * along)
        default: return CGPoint(x: 2, y: viewport.height * along)
        }
    }

    /// How long a key stays down: about 116 ms, rarely under 80 or over 150.
    public mutating func keyHold() -> Double { min(max(0.116 + 0.024 * gaussian(), 0.06), 0.2) }

    /// 0 for the left hand, 1 for the right, on a QWERTY keyboard.
    private static func hand(_ char: Character) -> Int? {
        let c = Character(char.lowercased())
        if "qwertasdfgzxcvb12345`~!@#$%".contains(c) { return 0 }
        if "yuiophjklnm67890-=[];',./\\^&*()_+{}:\"<>?|".contains(c) { return 1 }
        return nil
    }
}
