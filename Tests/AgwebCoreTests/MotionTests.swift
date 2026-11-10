import CoreGraphics
import Testing
import AgwebCore

@Test(arguments: [0.2, 120, 259, 600, 1400])
func pathEndsExactlyOnTarget(distance: Double) {
    var motion = Motion(seed: 7)
    let to = CGPoint(x: 100 + distance, y: 300)
    let path = motion.path(from: CGPoint(x: 100, y: 300), to: to, targetSize: 40)
    #expect(path.last?.point == to)
    #expect(path.allSatisfy { $0.pause >= 0 })
}

@Test func shortThrowsTakeFittsTime() {
    for seed in 0..<200 as Range<UInt64> {
        var motion = Motion(seed: seed)
        let total = motion.path(from: .zero, to: CGPoint(x: 200, y: 0), targetSize: 40).reduce(0) { $0 + $1.pause }
        #expect((0.19...1.2).contains(total))
    }
}

@Test func longThrowsFallShortThenCorrect() {
    var motion = Motion(seed: 3)
    let path = motion.path(from: .zero, to: CGPoint(x: 1000, y: 0), targetSize: 40)
    // The ballistic leg ends with the corrective pause, short of the target.
    let corner = path.first { $0.pause > 1.0 / 60 + 0.001 }
    #expect(corner.map { (850...960).contains($0.point.x) } == true)
}

@Test func aimStaysInsideTheTarget() {
    for seed in 0..<1000 as Range<UInt64> {
        var motion = Motion(seed: seed)
        for side in [1.0, 12, 44, 500] {
            let point = motion.aim(center: CGPoint(x: 50, y: 50), size: CGSize(width: side, height: side))
            #expect(abs(point.x - 50) <= side / 2 && abs(point.y - 50) <= side / 2)
        }
    }
}

@Test func keyDelaysArePositiveAndLongerAfterPunctuation() {
    var motion = Motion(seed: 11)
    let letters = (0..<500).map { _ in motion.keyDelay(after: "a") }
    let commas = (0..<500).map { _ in motion.keyDelay(after: ",") }
    #expect(letters.allSatisfy { $0 >= 0.06 })
    #expect(commas.reduce(0, +) > letters.reduce(0, +))
}

@Test func keyGapsAreSkewedLikeAPersons() {
    var motion = Motion(seed: 5)
    let gaps = (0..<4000).map { _ in motion.keyDelay(after: "a") }.sorted()
    let median = gaps[gaps.count / 2], mean = gaps.reduce(0, +) / Double(gaps.count)
    #expect((0.18...0.24).contains(median))
    // A long tail: the mean sits above the median.
    #expect(mean > median + 0.015)
}

@Test func alternatingHandsTypeFaster() {
    var a = Motion(seed: 9), b = Motion(seed: 9)
    let alternating = (0..<500).map { _ in a.keyDelay(after: "a", next: "k") }.reduce(0, +)
    let sameHand = (0..<500).map { _ in b.keyDelay(after: "a", next: "s") }.reduce(0, +)
    #expect(alternating < sameHand)
}

@Test func keysAreHeldLikeAPersons() {
    var motion = Motion(seed: 2)
    let holds = (0..<2000).map { _ in motion.keyHold() }
    #expect(holds.allSatisfy { (0.06...0.2).contains($0) })
    #expect(abs(holds.reduce(0, +) / Double(holds.count) - 0.116) < 0.005)
}

@Test func randomStaysInUnitInterval() {
    var motion = Motion(seed: 1)
    #expect((0..<10_000).allSatisfy { _ in (0..<1).contains(motion.random()) })
}

@Test func sameSeedSamePath() {
    var a = Motion(seed: 42), b = Motion(seed: 42)
    let pa = a.path(from: .zero, to: CGPoint(x: 300, y: 80), targetSize: 30)
    let pb = b.path(from: .zero, to: CGPoint(x: 300, y: 80), targetSize: 30)
    #expect(pa.map(\.point) == pb.map(\.point))
}
