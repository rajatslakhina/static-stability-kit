import XCTest
@testable import StaticStability

final class RecoveryGateTests: XCTestCase {
    private let window = Millis.minutes(30)

    func testJitterIsStableAcrossProcessesAndBoundedByTheWindow() {
        let jitter = RecoveryJitter(windowMillis: window)
        // Golden values recorded in an earlier process. A per-process-seeded hash
        // (Swift's Hasher) could not reproduce them.
        XCTAssertEqual(jitter.delayMillis(installationID: "device-A", recoveryEpoch: 1), 1_159_791)
        XCTAssertEqual(jitter.delayMillis(installationID: "device-B", recoveryEpoch: 1), 192_955)
        for i in 0..<1_000 {
            XCTAssertTrue((0..<window).contains(jitter.delayMillis(installationID: "d\(i)", recoveryEpoch: 3)))
        }
    }

    func testJitterChangesWithTheEpochSoTheSameDeviceIsNotAlwaysLast() {
        let jitter = RecoveryJitter(windowMillis: window)
        let delays = Set((1...20).map { jitter.delayMillis(installationID: "device-A", recoveryEpoch: $0) })
        XCTAssertGreaterThan(delays.count, 15)
    }

    func testEmptyWindowMeansNoDelay() {
        XCTAssertEqual(RecoveryJitter(windowMillis: 0).delayMillis(installationID: "x", recoveryEpoch: 1), 0)
        XCTAssertEqual(RecoveryJitter(windowMillis: -9).delayMillis(installationID: "x", recoveryEpoch: .min), 0)
    }

    func testFleetIsSpreadEvenlyAcrossTheWindow() {
        let jitter = RecoveryJitter(windowMillis: window)
        let delays = (0..<10_000).map { jitter.delayMillis(installationID: "install-\($0)", recoveryEpoch: 1) }
        XCTAssertTrue(RecoveryJitter.isRoughlyUniform(delays: delays, windowMillis: window, buckets: 10, tolerancePercent: 10))
    }

    func testUniformityCheckRejectsBrokenSpreads() {
        // The check above only means something if it fails on a broken jitter.
        let constant = [Int64](repeating: 42, count: 10_000)
        XCTAssertFalse(RecoveryJitter.isRoughlyUniform(delays: constant, windowMillis: window, buckets: 10, tolerancePercent: 10))
        let firstHalfOnly = (0..<10_000).map { Int64($0) % (window / 2) }
        XCTAssertFalse(RecoveryJitter.isRoughlyUniform(delays: firstHalfOnly, windowMillis: window, buckets: 10, tolerancePercent: 10))
        let outOfRange = [Int64](repeating: window, count: 10)
        XCTAssertFalse(RecoveryJitter.isRoughlyUniform(delays: outOfRange, windowMillis: window, buckets: 1, tolerancePercent: 100))
        XCTAssertFalse(RecoveryJitter.isRoughlyUniform(delays: [], windowMillis: window, buckets: 10, tolerancePercent: 10))
        XCTAssertFalse(RecoveryJitter.isRoughlyUniform(delays: [1], windowMillis: 0, buckets: 10, tolerancePercent: 10))
        // A window so large that delay * buckets overflows 64 bits still slices correctly.
        let huge = Int64.max / 2
        let spread = (0..<1_000).map { Int64($0) * (huge / 1_000) }
        XCTAssertTrue(RecoveryJitter.isRoughlyUniform(delays: spread, windowMillis: huge, buckets: 10, tolerancePercent: 1))
        // A hostile bucket count is refused rather than allocated.
        XCTAssertFalse(RecoveryJitter.isRoughlyUniform(delays: [1], windowMillis: 10, buckets: .max, tolerancePercent: 10))
        XCTAssertFalse(RecoveryJitter.isRoughlyUniform(delays: [1], windowMillis: 10, buckets: 10_001, tolerancePercent: 10))
    }

    func testTokenBucketKeepsFractionalRefill() {
        // 1 token per minute, polled every 10 seconds: a bucket that discards the
        // remainder on each poll never refills at all.
        var bucket = TokenBucket(capacity: 5, refillPerMinute: 1, tokens: 0, at: .minute(0))
        var granted = 0
        for tick in 1...36 {  // 6 minutes
            if bucket.tryTake(at: Instant(millisSinceEpoch: Millis.seconds(Int64(tick * 10)))) { granted += 1 }
        }
        XCTAssertEqual(granted, 6)
    }

    func testTokenBucketCapsAtCapacityAndStartsWhereTold() {
        var bucket = TokenBucket(capacity: 3, refillPerMinute: 60, tokens: 99, at: .minute(0))
        XCTAssertEqual(bucket.tokens, 3)
        let afterAnHour = Instant.minute(60)
        var taken = 0
        while bucket.tryTake(at: afterAnHour) { taken += 1 }
        XCTAssertEqual(taken, 3, "an hour idle still only bursts `capacity`")
    }

    func testTokenBucketIgnoresClockGoingBackwards() {
        var bucket = TokenBucket(capacity: 2, refillPerMinute: 1, tokens: 2, at: .minute(10))
        // A clock set back ten minutes neither drains the bucket nor moves its reference.
        XCTAssertTrue(bucket.tryTake(at: .minute(0)))
        XCTAssertTrue(bucket.tryTake(at: .minute(0)))
        XCTAssertFalse(bucket.tryTake(at: .minute(0)))
        XCTAssertTrue(bucket.tryTake(at: .minute(11)), "one minute after the reference, not eleven")
        XCTAssertFalse(bucket.tryTake(at: .minute(11)))
    }

    func testTokenBucketSurvivesHostileRatesAndTimes() {
        var bucket = TokenBucket(capacity: .max, refillPerMinute: .max, tokens: 0, at: Instant(millisSinceEpoch: .min))
        XCTAssertTrue(bucket.tryTake(at: Instant(millisSinceEpoch: .max)))
        var zero = TokenBucket(capacity: -1, refillPerMinute: -1, at: .minute(0))
        XCTAssertFalse(zero.tryTake(at: .minute(1_000)))
    }

    func testGateWaitsForItsSlotThenRateLimits() {
        let jitter = RecoveryJitter(windowMillis: window)
        var gate = RecoveryGate(
            installationID: "device-A",
            jitter: jitter,
            bucket: TokenBucket(capacity: 2, refillPerMinute: 1, tokens: 2, at: .minute(0))
        )
        gate.dependencyRecovered(at: .minute(100), epoch: 1)
        let slot = Instant.minute(100).advanced(byMillis: jitter.delayMillis(installationID: "device-A", recoveryEpoch: 1))
        XCTAssertEqual(gate.notBefore, slot)
        if slot > .minute(100) {
            XCTAssertFalse(gate.mayPush(at: slot.advanced(byMillis: -1)), "not before the slot")
        }
        XCTAssertTrue(gate.mayPush(at: slot))
        XCTAssertTrue(gate.mayPush(at: slot))
        XCTAssertFalse(gate.mayPush(at: slot), "burst of 2 used up")
        XCTAssertTrue(gate.mayPush(at: slot.advanced(byMillis: Millis.minutes(1))))
        XCTAssertNil(gate.notBefore)
    }
}
