import XCTest
@testable import StaticStability

final class FoundationTests: XCTestCase {
    func testSaturatingAddClampsAtBothBounds() {
        XCTAssertEqual(Saturating.add(Int64.max, 1), .max)
        XCTAssertEqual(Saturating.add(Int64.min, -1), .min)
        XCTAssertEqual(Saturating.add(Int64(2), 3), 5)
        XCTAssertEqual(Saturating.add(Int.max, 1), .max)
        XCTAssertEqual(Saturating.add(Int.min, -1), .min)
    }

    func testSaturatingSubtractAndMultiplyClamp() {
        XCTAssertEqual(Saturating.subtract(Int64.min, 1), .min)
        XCTAssertEqual(Saturating.subtract(Int64.max, -1), .max)
        XCTAssertEqual(Saturating.multiply(Int64.max, 2), .max)
        XCTAssertEqual(Saturating.multiply(Int64.min, 2), .min)
        XCTAssertEqual(Saturating.multiply(Int64.min, -1), .max)
        XCTAssertEqual(Saturating.multiply(Int64(-4), 5), -20)
    }

    func testDoublingStopsAtCapAndIgnoresNegativeExponent() {
        XCTAssertEqual(Saturating.doubling(1_000, times: 0, cap: 100_000), 1_000)
        XCTAssertEqual(Saturating.doubling(1_000, times: 3, cap: 100_000), 8_000)
        XCTAssertEqual(Saturating.doubling(1_000, times: 500, cap: 100_000), 100_000)
        XCTAssertEqual(Saturating.doubling(1_000, times: -4, cap: 100_000), 1_000)
        XCTAssertEqual(Saturating.doubling(Int64.max / 2, times: Int.max, cap: .max), .max)
        XCTAssertEqual(Saturating.doubling(3, times: 62, cap: .max), .max)
        XCTAssertEqual(Saturating.doubling(1, times: 62, cap: .max), Int64(1) << 62)
        XCTAssertEqual(Saturating.doubling(5, times: 2, cap: -1), 0)
        XCTAssertEqual(Saturating.doubling(0, times: 10, cap: 100), 0)
    }

    func testInstantFromDateClampsNonFiniteAndOutOfRange() {
        XCTAssertEqual(Instant(Date(timeIntervalSince1970: 1.5)).millisSinceEpoch, 1_500)
        XCTAssertEqual(Instant(Date(timeIntervalSince1970: -0.0015)).millisSinceEpoch, -2)
        XCTAssertEqual(Instant(Date(timeIntervalSince1970: .infinity)).millisSinceEpoch, .max)
        XCTAssertEqual(Instant(Date(timeIntervalSince1970: -.infinity)).millisSinceEpoch, .min)
        XCTAssertEqual(Instant(Date(timeIntervalSince1970: .nan)).millisSinceEpoch, 0)
        XCTAssertEqual(Instant(Date(timeIntervalSince1970: 1e300)).millisSinceEpoch, .max)
    }

    func testMillisConstructorsSaturate() {
        XCTAssertEqual(Millis.minutes(2), 120_000)
        XCTAssertEqual(Millis.days(Int64.max), .max)
        XCTAssertEqual(Millis.hours(Int64.min), .min)
    }

    func testInstantArithmeticSaturatesInsteadOfTrapping() {
        let far = Instant(millisSinceEpoch: .max)
        XCTAssertEqual(far.advanced(byMillis: Millis.days(1)).millisSinceEpoch, .max)
        XCTAssertEqual(far.millis(since: Instant(millisSinceEpoch: .min)), .max)
        XCTAssertEqual(Instant.minute(3).millis(since: .minute(1)), 120_000)
        XCTAssertEqual(Instant.minute(1).millis(since: .minute(3)), -120_000)
    }

    func testMonotonicGuardNeverMovesBackwards() {
        var guardrail = MonotonicTimeGuard()
        XCTAssertEqual(guardrail.observe(.minute(100)), .minute(100))
        // The user sets the clock back a day: the guard keeps the later time.
        XCTAssertEqual(guardrail.observe(.minute(100 - 1_440)), .minute(100))
        XCTAssertEqual(guardrail.observe(.minute(130)), .minute(130))
        XCTAssertEqual(guardrail.highWater, .minute(130))
    }

    func testReanchorRecoversFromAClockSetForwardAndBack() {
        var guardrail = MonotonicTimeGuard()
        _ = guardrail.observe(.minute(525_600))  // clock set a year ahead
        XCTAssertEqual(guardrail.observe(.minute(10)), .minute(525_600), "stuck in the future")
        guardrail.reanchor(to: .minute(10))       // e.g. a server timestamp
        XCTAssertEqual(guardrail.observe(.minute(11)), .minute(11))
    }

    func testReanchoringToAnOlderTimeReopensRollbackByTheDifference() {
        // Documented hazard: anchoring to a stale "trusted" time (a days-old signed
        // transaction date) moves the mark back, and the clock can then be set back
        // into that gap. Only anchor to a current server time.
        var guardrail = MonotonicTimeGuard()
        _ = guardrail.observe(.minute(1_000))
        guardrail.reanchor(to: .minute(400))
        XCTAssertEqual(guardrail.observe(.minute(500)), .minute(500), "500 < 1,000 is accepted again")
    }

    func testFNV1aMatchesPublishedVectors() {
        // Reference values for 64-bit FNV-1a. A process-seeded hash (Hasher) would
        // produce different values on every run and fail here.
        XCTAssertEqual(StableHash.fnv1a64(""), 0xcbf2_9ce4_8422_2325)
        XCTAssertEqual(StableHash.fnv1a64("a"), 0xaf63_dc4c_8601_ec8c)
        XCTAssertEqual(StableHash.fnv1a64("foobar"), 0x8594_4171_f739_67e8)
    }

    func testSplitMixMatchesReferenceSequence() {
        // First outputs of SplitMix64 seeded with 0, as published with the algorithm.
        var rng = SplitMix64(seed: 0)
        XCTAssertEqual(rng.next(), 0xe220_a839_7b1d_cdaf)
        XCTAssertEqual(rng.next(), 0x6e78_9e6a_a1b9_65f4)
    }

    func testSplitMixHelpersHandleDegenerateBounds() {
        var rng = SplitMix64(seed: 9)
        XCTAssertEqual(rng.below(0), 0)
        XCTAssertEqual(rng.below(-5), 0)
        for _ in 0..<100 { XCTAssertFalse(rng.chance(percent: -10)) }
        for _ in 0..<100 { XCTAssertTrue(rng.chance(percent: 250)) }
        for _ in 0..<100 { XCTAssertTrue((0..<7).contains(rng.below(7))) }
    }
}
