import XCTest
@testable import StaticStability

final class CircuitBreakerTests: XCTestCase {
    private let policy = BreakerPolicy(
        windowSize: 10,
        minimumSamples: 5,
        failureThresholdPercent: 50,
        baseCooldownMillis: Millis.seconds(30),
        maxCooldownMillis: Millis.minutes(4),
        cooldownJitterMillis: 0,
        halfOpenSuccessesToClose: 2
    )

    private func feed(_ breaker: inout CircuitBreaker, _ outcomes: [Bool], at now: Instant = .minute(0)) {
        for success in outcomes {
            XCTAssertTrue(breaker.permitsRequest(at: now))
            breaker.record(success: success, at: now)
        }
    }

    func testSingleFailureDoesNotTrip() {
        var breaker = CircuitBreaker(policy: policy)
        feed(&breaker, [false])
        XCTAssertEqual(breaker.state, .closed)
    }

    func testFailuresBelowMinimumSamplesDoNotTripEvenAtHundredPercent() {
        var breaker = CircuitBreaker(policy: policy)
        feed(&breaker, [false, false, false, false])
        XCTAssertEqual(breaker.state, .closed, "4 failures < minimumSamples 5")
    }

    func testTripsWhenFailureRateReachesThresholdOverMinimumSamples() {
        var breaker = CircuitBreaker(policy: policy)
        feed(&breaker, [true, true, false, false, false])
        XCTAssertEqual(breaker.state, .open(until: Instant.minute(0).advanced(byMillis: Millis.seconds(30))))
    }

    func testRateBelowThresholdStaysClosed() {
        var breaker = CircuitBreaker(policy: policy)
        feed(&breaker, [true, true, true, false, false, true, true, true, false, true])
        XCTAssertEqual(breaker.state, .closed, "3/10 = 30% < 50%")
    }

    func testOldOutcomesAgeOutOfTheWindow() {
        var breaker = CircuitBreaker(policy: policy)
        // Two early failures, then ten successes push them out of the 10-slot window.
        // If they never aged out, the 4th later failure would make 6/10 and trip.
        feed(&breaker, [false, false] + Array(repeating: true, count: 10))
        feed(&breaker, [false, false, false, false])
        XCTAssertEqual(breaker.state, .closed, "only 4 failures in the current window of 10")
        feed(&breaker, [false])
        XCTAssertNotEqual(breaker.state, .closed, "5/10 failures now trips")
    }

    func testOpenRefusesUntilCooldownThenAdmitsExactlyOneProbe() {
        var breaker = CircuitBreaker(policy: policy)
        feed(&breaker, Array(repeating: false, count: 5))
        let reopen = Instant.minute(0).advanced(byMillis: Millis.seconds(30))
        XCTAssertFalse(breaker.permitsRequest(at: Instant.minute(0).advanced(byMillis: Millis.seconds(29))))
        XCTAssertEqual(breaker.availability(at: .minute(0)), .unavailable(retryAfter: reopen))
        XCTAssertTrue(breaker.permitsRequest(at: reopen))
        XCTAssertEqual(breaker.state, .halfOpen(successes: 0, probeInFlight: true))
        XCTAssertFalse(breaker.permitsRequest(at: reopen), "second concurrent probe refused")
        XCTAssertEqual(breaker.availability(at: reopen), .recovering)
    }

    func testHalfOpenClosesAfterRequiredSuccessesAndCountsRecovery() {
        var breaker = CircuitBreaker(policy: policy)
        feed(&breaker, Array(repeating: false, count: 5))
        let t = Instant.minute(1)
        XCTAssertTrue(breaker.permitsRequest(at: t))
        XCTAssertFalse(breaker.record(success: true, at: t), "1 of 2 successes: still half-open")
        XCTAssertEqual(breaker.state, .halfOpen(successes: 1, probeInFlight: false))
        XCTAssertTrue(breaker.permitsRequest(at: t))
        XCTAssertTrue(breaker.record(success: true, at: t), "second success closes")
        XCTAssertEqual(breaker.state, .closed)
        XCTAssertEqual(breaker.recoveries, 1)
        XCTAssertEqual(breaker.consecutiveTrips, 0)
    }

    func testHalfOpenFailureReopensWithDoubledCooldownCappedAtMax() {
        var breaker = CircuitBreaker(policy: policy)
        feed(&breaker, Array(repeating: false, count: 5))
        var now = Instant.minute(0)
        var cooldowns: [Int64] = []
        for _ in 0..<6 {
            guard case .open(let until) = breaker.state else { return XCTFail("expected open") }
            cooldowns.append(until.millis(since: now))
            now = until
            XCTAssertTrue(breaker.permitsRequest(at: now))
            breaker.record(success: false, at: now)
        }
        XCTAssertEqual(cooldowns, [30_000, 60_000, 120_000, 240_000, 240_000, 240_000])
    }

    func testStalePermitFromBeforeTheTripCannotPoseAsTheProbe() {
        var breaker = CircuitBreaker(policy: policy)
        // A slow request admitted while closed...
        guard let slow = breaker.requestPermit(at: .minute(0)) else { return XCTFail("closed admits") }
        XCTAssertFalse(slow.isProbe)
        // ...the breaker trips on other traffic...
        for _ in 0..<5 {
            guard let p = breaker.requestPermit(at: .minute(0)) else { return XCTFail() }
            breaker.record(p, success: false, at: .minute(0))
        }
        // ...and after the cooldown one probe goes out.
        let afterCooldown = Instant.minute(1)
        guard let probe = breaker.requestPermit(at: afterCooldown) else { return XCTFail("probe admitted") }
        XCTAssertTrue(probe.isProbe)
        // The slow pre-trip request finally succeeds: it must not count as the probe.
        XCTAssertFalse(breaker.record(slow, success: true, at: afterCooldown))
        XCTAssertEqual(breaker.state, .halfOpen(successes: 0, probeInFlight: true))
        XCTAssertNil(breaker.requestPermit(at: afterCooldown), "still one probe at a time")
        // The real probe's result is what counts.
        breaker.record(probe, success: true, at: afterCooldown)
        XCTAssertEqual(breaker.state, .halfOpen(successes: 1, probeInFlight: false))
    }

    func testProbePermitAfterTheBreakerClosedIsIgnored() {
        var breaker = CircuitBreaker(policy: BreakerPolicy(windowSize: 1, minimumSamples: 1, failureThresholdPercent: 100,
                                                           baseCooldownMillis: 0, maxCooldownMillis: 0,
                                                           cooldownJitterMillis: 0, halfOpenSuccessesToClose: 1))
        guard let first = breaker.requestPermit(at: .minute(0)) else { return XCTFail() }
        breaker.record(first, success: false, at: .minute(0))
        guard let probe = breaker.requestPermit(at: .minute(0)) else { return XCTFail() }
        XCTAssertTrue(breaker.record(probe, success: true, at: .minute(0)), "probe closes the breaker")
        XCTAssertEqual(breaker.state, .closed)
        // The same probe permit recorded again (a duplicate callback) changes nothing.
        let before = breaker
        XCTAssertFalse(breaker.record(probe, success: false, at: .minute(0)))
        XCTAssertEqual(breaker, before)
    }

    func testDuplicateResultFromAnEarlierProbeIsIgnoredByTheNextProbe() {
        var breaker = CircuitBreaker(policy: policy)
        feed(&breaker, Array(repeating: false, count: 5))
        guard let firstProbe = breaker.requestPermit(at: .minute(1)) else { return XCTFail() }
        breaker.record(firstProbe, success: false, at: .minute(1))   // re-trips, 60 s cooldown
        guard let secondProbe = breaker.requestPermit(at: .minute(3)) else { return XCTFail() }
        // The first probe's callback fires again (a retry layer, a duplicate delegate call).
        XCTAssertFalse(breaker.record(firstProbe, success: true, at: .minute(3)))
        XCTAssertEqual(breaker.state, .halfOpen(successes: 0, probeInFlight: true))
        breaker.record(secondProbe, success: true, at: .minute(3))
        XCTAssertEqual(breaker.state, .halfOpen(successes: 1, probeInFlight: false))
    }

    func testDuplicateResultFromThePreviousProbeInTheSameHalfOpenIsIgnored() {
        var breaker = CircuitBreaker(policy: policy)  // needs 2 probe successes to close
        feed(&breaker, Array(repeating: false, count: 5))
        guard let p1 = breaker.requestPermit(at: .minute(1)) else { return XCTFail() }
        breaker.record(p1, success: true, at: .minute(1))
        XCTAssertEqual(breaker.state, .halfOpen(successes: 1, probeInFlight: false))
        guard let p2 = breaker.requestPermit(at: .minute(1)) else { return XCTFail() }
        // P1's callback fires a second time while P2 is out: it must not close the breaker.
        XCTAssertFalse(breaker.record(p1, success: true, at: .minute(1)))
        XCTAssertEqual(breaker.state, .halfOpen(successes: 1, probeInFlight: true))
        XCTAssertTrue(breaker.record(p2, success: true, at: .minute(1)), "the real second probe closes it")
    }

    func testHalfOpenIgnoresBoolRecordWhenNoProbeIsInFlight() {
        var breaker = CircuitBreaker(policy: policy)
        feed(&breaker, Array(repeating: false, count: 5))
        XCTAssertTrue(breaker.permitsRequest(at: .minute(1)))
        breaker.record(success: true, at: .minute(1))
        XCTAssertEqual(breaker.state, .halfOpen(successes: 1, probeInFlight: false))
        // A stray result with no probe out must not be counted as the second success.
        XCTAssertFalse(breaker.record(success: true, at: .minute(1)))
        XCTAssertEqual(breaker.state, .halfOpen(successes: 1, probeInFlight: false))
    }

    func testLateOutcomeWhileOpenIsIgnored() {
        var breaker = CircuitBreaker(policy: policy)
        feed(&breaker, Array(repeating: false, count: 5))
        let before = breaker
        breaker.record(success: true, at: .minute(0))
        XCTAssertEqual(breaker, before)
    }

    func testJitterSpreadsReopenTimesAcrossClientsDeterministically() {
        let jittered = BreakerPolicy(
            windowSize: 5, minimumSamples: 5, failureThresholdPercent: 100,
            baseCooldownMillis: Millis.minutes(1), maxCooldownMillis: Millis.minutes(1),
            cooldownJitterMillis: Millis.minutes(4), halfOpenSuccessesToClose: 1
        )
        func reopenTime(seed: UInt64) -> Int64? {
            var breaker = CircuitBreaker(policy: jittered, jitterSeed: seed)
            for _ in 0..<5 {
                _ = breaker.permitsRequest(at: .minute(0))
                breaker.record(success: false, at: .minute(0))
            }
            guard case .open(let until) = breaker.state else { return nil }
            return until.millisSinceEpoch
        }
        let times = (0..<200).compactMap { reopenTime(seed: UInt64($0)) }
        XCTAssertEqual(times.count, 200)
        XCTAssertTrue(times.allSatisfy { (60_000...300_000).contains($0) })
        XCTAssertGreaterThan(Set(times).count, 150, "200 clients must not reopen in lockstep")
        // Golden value recorded from an earlier process: catches the jitter being
        // switched to a per-process-seeded hash.
        XCTAssertEqual(reopenTime(seed: 1), 187_602)
    }

    func testPolicyClampsHostileValues() {
        let hostile = BreakerPolicy(
            windowSize: -3, minimumSamples: 99, failureThresholdPercent: 900,
            baseCooldownMillis: -5, maxCooldownMillis: -10,
            cooldownJitterMillis: .max, halfOpenSuccessesToClose: 0
        )
        XCTAssertEqual(hostile.windowSize, 1)
        XCTAssertEqual(hostile.minimumSamples, 1)
        XCTAssertEqual(hostile.failureThresholdPercent, 100)
        XCTAssertEqual(hostile.baseCooldownMillis, 0)
        XCTAssertEqual(hostile.maxCooldownMillis, 0)
        XCTAssertEqual(hostile.cooldownJitterMillis, .max - 1)
        XCTAssertEqual(hostile.halfOpenSuccessesToClose, 1)
        // And a breaker built from it trips and reopens without trapping.
        var breaker = CircuitBreaker(policy: hostile, jitterSeed: .max)
        XCTAssertTrue(breaker.permitsRequest(at: Instant(millisSinceEpoch: .max - 1)))
        breaker.record(success: false, at: Instant(millisSinceEpoch: .max - 1))
        XCTAssertEqual(breaker.availability(at: Instant(millisSinceEpoch: .max)), .recovering)
    }

    func testOutcomeWindowRingKeepsCountsConsistent() {
        var window = OutcomeWindow(capacity: 3)
        for failure in [true, true, false, true, false, false, false] {
            window.append(failure: failure)
        }
        XCTAssertEqual(window.count, 3)
        XCTAssertEqual(window.failures, 0)
        window.append(failure: true)
        XCTAssertEqual(window.failures, 1)
        window.reset()
        XCTAssertEqual(window.count, 0)
        XCTAssertEqual(window.failures, 0)
    }
}
