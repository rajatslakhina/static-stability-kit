import XCTest
@testable import StaticStability

final class LastKnownGoodTests: XCTestCase {
    private struct Flags: Equatable, Sendable { var newCheckout: Bool; var version: Int }
    private let bundled = Flags(newCheckout: false, version: 0)

    func testNeverFetchedServesBundledDefault() {
        let config = LastKnownGood(bundled: bundled)
        XCTAssertEqual(config.serve(at: .minute(5)), ServedConfig(value: bundled, provenance: .bundledDefault(.neverFetched)))
    }

    func testFreshThenLastKnownGoodForeverByDefault() {
        var config = LastKnownGood(bundled: bundled, policy: StalenessPolicy(freshForMillis: Millis.minutes(15)))
        let remote = Flags(newCheckout: true, version: 3)
        XCTAssertEqual(config.offer(remote, fetchedAt: .minute(0), isValid: { _ in true }), .accepted)
        XCTAssertEqual(config.serve(at: .minute(10)).provenance, .fresh(ageMillis: Millis.minutes(10)))
        let weekLater = config.serve(at: .minute(7 * 24 * 60))
        XCTAssertEqual(weekLater.value, remote, "static stability: an outage never reverts behaviour")
        XCTAssertEqual(weekLater.provenance, .lastKnownGood(ageMillis: Millis.days(7)))
    }

    func testMaxStaleFallsBackToBundled() {
        var config = LastKnownGood(
            bundled: bundled,
            policy: StalenessPolicy(freshForMillis: Millis.minutes(15), maxStaleMillis: Millis.hours(1))
        )
        _ = config.offer(Flags(newCheckout: true, version: 3), fetchedAt: .minute(0), isValid: { _ in true })
        XCTAssertEqual(config.serve(at: .minute(60)).value.version, 3, "exactly at the limit still serves it")
        XCTAssertEqual(config.serve(at: .minute(61)).provenance, .bundledDefault(.tooStale(ageMillis: Millis.minutes(61))))
    }

    func testInvalidPushIsRejectedAndPreviousValueKept() {
        var config = LastKnownGood(bundled: bundled)
        let good = Flags(newCheckout: true, version: 3)
        _ = config.offer(good, fetchedAt: .minute(0), isValid: { _ in true })
        let broken = Flags(newCheckout: true, version: -1)
        XCTAssertEqual(config.offer(broken, fetchedAt: .minute(5), isValid: { $0.version >= 0 }), .rejectedInvalid)
        XCTAssertEqual(config.serve(at: .minute(6)).value, good)
    }

    func testOutOfOrderResponseCannotRollBack() {
        var config = LastKnownGood(bundled: bundled)
        _ = config.offer(Flags(newCheckout: true, version: 4), fetchedAt: .minute(10), isValid: { _ in true })
        XCTAssertEqual(config.offer(Flags(newCheckout: false, version: 3), fetchedAt: .minute(9), isValid: { _ in true }),
                       .rejectedOutOfOrder)
        XCTAssertEqual(config.serve(at: .minute(11)).value.version, 4)
    }

    func testClockBehindFetchTimeReportsZeroAge() {
        var config = LastKnownGood(bundled: bundled)
        _ = config.offer(Flags(newCheckout: true, version: 1), fetchedAt: .minute(100), isValid: { _ in true })
        XCTAssertEqual(config.serve(at: .minute(40)).provenance, .fresh(ageMillis: 0))
    }
}

final class SessionContinuityTests: XCTestCase {
    func testProviderOutageNeverSignsOutWithinBudget() {
        var session = SessionContinuity(maxUnverifiedMillis: Millis.days(7), lastVerifiedAt: .minute(0))
        XCTAssertEqual(session.evaluate(.unavailable, at: .minute(180)), .activeUnverified(unverifiedForMillis: Millis.minutes(180)))
        XCTAssertTrue(session.evaluate(.unavailable, at: .minute(7 * 24 * 60)).hasSession)
    }

    func testOverBudgetIsRestrictedNotSignedOut() {
        var session = SessionContinuity(maxUnverifiedMillis: Millis.hours(1), lastVerifiedAt: .minute(0))
        let decision = session.evaluate(.unavailable, at: .minute(61))
        XCTAssertEqual(decision, .restricted(unverifiedForMillis: Millis.minutes(61)))
        XCTAssertTrue(decision.hasSession)
    }

    func testPositiveRevocationSignsOutImmediately() {
        var session = SessionContinuity(lastVerifiedAt: .minute(0))
        XCTAssertEqual(session.evaluate(.revoked, at: .minute(1)), .signedOut(.credentialRevoked))
        XCTAssertNil(session.lastVerifiedAt)
        XCTAssertEqual(session.evaluate(.unavailable, at: .minute(2)), .signedOut(.neverVerified),
                       "a revoked session cannot be resurrected by a later outage")
    }

    func testNotFoundSignsOut() {
        var session = SessionContinuity(lastVerifiedAt: .minute(0))
        XCTAssertEqual(session.evaluate(.notFound, at: .minute(1)), .signedOut(.credentialNotFound))
    }

    func testAuthorizedResetsTheBudget() {
        var session = SessionContinuity(maxUnverifiedMillis: Millis.hours(1), lastVerifiedAt: .minute(0))
        _ = session.evaluate(.authorized, at: .minute(50))
        XCTAssertEqual(session.evaluate(.unavailable, at: .minute(100)), .activeUnverified(unverifiedForMillis: Millis.minutes(50)))
    }

    func testNoPriorVerificationMeansNoSessionToContinue() {
        let session = SessionContinuity()
        XCTAssertEqual(session.decisionWithoutProvider(at: .minute(0)), .signedOut(.neverVerified))
    }

    func testClockRollbackWithGuardCannotStretchTheBudget() {
        var session = SessionContinuity(maxUnverifiedMillis: Millis.hours(1), lastVerifiedAt: .minute(0))
        var clock = MonotonicTimeGuard()
        _ = clock.observe(.minute(90))
        // The user sets the clock back to minute 10 to look "recently verified".
        let effective = clock.observe(.minute(10))
        XCTAssertEqual(session.evaluate(.unavailable, at: effective), .restricted(unverifiedForMillis: Millis.minutes(90)))
    }
}

final class EntitlementPolicyTests: XCTestCase {
    private let policy = EntitlementPolicy(outageGraceMillis: Millis.hours(48))
    private func monthly(expiresAtMinute: Int, revokedAtMinute: Int? = nil) -> VerifiedEntitlement {
        VerifiedEntitlement(
            productID: "pro.monthly",
            expiresAt: .minute(expiresAtMinute),
            revokedAt: revokedAtMinute.map { .minute($0) },
            verifiedAt: .minute(0)
        )
    }

    func testInsideExpiryIsGrantedWhateverTheStoreSays() {
        XCTAssertEqual(policy.decide(monthly(expiresAtMinute: 100), storeReachable: true, at: .minute(99)), .granted(.verified))
        XCTAssertEqual(policy.decide(monthly(expiresAtMinute: 100), storeReachable: false, at: .minute(99)), .granted(.verified))
    }

    func testPastExpiryWithStoreReachableIsDenied() {
        XCTAssertEqual(policy.decide(monthly(expiresAtMinute: 100), storeReachable: true, at: .minute(100)), .denied(.expired))
    }

    func testPastExpiryDuringOutageGetsBoundedGrace() {
        XCTAssertEqual(
            policy.decide(monthly(expiresAtMinute: 100), storeReachable: false, at: .minute(160)),
            .granted(.outageGrace(remainingMillis: Millis.hours(48) - Millis.minutes(60)))
        )
        let graceEnd = 100 + 48 * 60
        XCTAssertTrue(policy.decide(monthly(expiresAtMinute: 100), storeReachable: false, at: .minute(graceEnd - 1)).isGranted)
        XCTAssertEqual(policy.decide(monthly(expiresAtMinute: 100), storeReachable: false, at: .minute(graceEnd)), .denied(.expired))
    }

    func testRevocationWinsOverGrace() {
        let refunded = monthly(expiresAtMinute: 100, revokedAtMinute: 50)
        XCTAssertEqual(policy.decide(refunded, storeReachable: false, at: .minute(60)), .denied(.revoked))
        XCTAssertTrue(policy.decide(refunded, storeReachable: false, at: .minute(40)).isGranted, "revoked in the future")
    }

    func testNonExpiringAndMissing() {
        let lifetime = VerifiedEntitlement(productID: "pro.lifetime", expiresAt: nil, verifiedAt: .minute(0))
        XCTAssertEqual(policy.decide(lifetime, storeReachable: true, at: .minute(.max / 120_000)), .granted(.verified))
        XCTAssertEqual(policy.decide(nil, storeReachable: false, at: .minute(0)), .denied(.noVerifiedTransaction))
    }

    func testHugeGraceAndFarFutureExpiryDoNotTrap() {
        let huge = EntitlementPolicy(outageGraceMillis: .max)
        let far = VerifiedEntitlement(productID: "p", expiresAt: Instant(millisSinceEpoch: .max - 10), verifiedAt: .minute(0))
        XCTAssertTrue(huge.decide(far, storeReachable: false, at: Instant(millisSinceEpoch: .max - 1)).isGranted)
        XCTAssertEqual(EntitlementPolicy(outageGraceMillis: -5).outageGraceMillis, 0)
    }
}

final class CapabilityRouterTests: XCTestCase {
    private let router = CapabilityRouter()
    private let draft = AITask(name: "Draft reply", required: [.shortRewrite], preferred: [.toolUse])
    private let research = AITask(name: "Ask with sources", required: [.webGrounding])

    func testCloudAvailableServesFull() {
        XCTAssertEqual(router.route(draft, isAvailable: { _ in true }), .full(backend: InferenceBackend.cloud.name))
    }

    func testCloudDownFallsBackOnDeviceAndSaysWhatWasLost() {
        let route = router.route(draft, isAvailable: { $0 != .cloud })
        guard case .reduced(let backend, let lost, let notice) = route else { return XCTFail("expected reduced, got \(route)") }
        XCTAssertEqual(backend, InferenceBackend.onDevice.name)
        XCTAssertEqual(lost, [.toolUse])
        XCTAssertTrue(notice.contains("tool use"))
    }

    func testTaskNeedingCloudOnlyCapabilityIsUnavailableNotSilentlyDowngraded() {
        let route = router.route(research, isAvailable: { $0 != .cloud })
        XCTAssertEqual(route.isServed, false)
        guard case .unavailable(let missing, _) = route else { return XCTFail("expected unavailable") }
        XCTAssertEqual(missing, [.webGrounding])
    }

    func testOnDeviceFullWhenTaskFitsIt() {
        let classify = AITask(name: "Triage", required: [.classification])
        XCTAssertEqual(router.route(classify, isAvailable: { $0 != .cloud }), .full(backend: InferenceBackend.onDevice.name))
    }

    func testNothingAvailableListsEveryRequiredCapability() {
        let task = AITask(name: "Both", required: [.extraction, .webGrounding])
        guard case .unavailable(let missing, _) = router.route(task, isAvailable: { _ in false }) else { return XCTFail() }
        XCTAssertEqual(missing, [.extraction, .webGrounding])
    }

    func testPreferredOverlappingRequiredIsIgnored() {
        let task = AITask(name: "T", required: [.shortRewrite], preferred: [.shortRewrite])
        XCTAssertTrue(task.preferred.isEmpty)
    }
}

final class DegradationPlannerTests: XCTestCase {
    private func inputs(
        session: SessionDecision = .active(verifiedAgoMillis: 0),
        entitlement: EntitlementDecision = .granted(.verified),
        pending: Int = 0,
        capacity: Int = 10,
        syncAvailable: Bool = true,
        config: ConfigProvenance = .fresh(ageMillis: 0),
        ai: AIRoute = .full(backend: "cloud")
    ) -> PostureInputs {
        PostureInputs(
            session: session, entitlement: entitlement, pendingWrites: pending, outboxCapacity: capacity,
            oldestPendingAgeMillis: pending > 0 ? Millis.minutes(12) : nil, syncAvailable: syncAvailable,
            configProvenance: config, aiRoute: ai
        )
    }

    func testHealthyIsAllFull() {
        let posture = DegradationPlanner.posture(inputs())
        XCTAssertEqual(posture.count, 5)
        XCTAssertTrue(posture.allSatisfy { $0.mode == .full })
    }

    func testOutagePostureIsDegradedNotUnavailableForCoreFeatures() {
        let posture = DegradationPlanner.posture(inputs(
            session: .activeUnverified(unverifiedForMillis: Millis.minutes(90)),
            entitlement: .granted(.outageGrace(remainingMillis: Millis.hours(47))),
            pending: 3, syncAvailable: false,
            config: .lastKnownGood(ageMillis: Millis.minutes(95))
        ))
        let byDependency = Dictionary(uniqueKeysWithValues: posture.map { ($0.dependency, $0.mode) })
        XCTAssertEqual(byDependency[.identity], .degraded("Signed in on this device; Apple sign-in unreachable for 1 h 30 min."))
        XCTAssertEqual(byDependency[.storeKit], .degraded("Unlocked from your last receipt; App Store unreachable. Grace ends in 47 h 0 min."))
        XCTAssertEqual(byDependency[.cloudSync], .degraded("3 change(s) saved on this device, oldest 12 min old; will sync when iCloud returns."))
        XCTAssertEqual(byDependency[.remoteConfig], .degraded("Using flags from 1 h 35 min ago."))
        XCTAssertEqual(byDependency[.cloudAI], .full)
    }

    func testFullOutboxAndUnavailableModes() {
        let posture = DegradationPlanner.posture(inputs(
            session: .signedOut(.credentialRevoked),
            entitlement: .denied(.expired),
            pending: 10, capacity: 10,
            ai: .unavailable(missing: [.webGrounding], notice: "no web")
        ))
        let modes = posture.map(\.mode)
        XCTAssertEqual(modes[0], .unavailable("Signed out: Apple ID access was revoked."))
        XCTAssertEqual(modes[1], .unavailable("Subscription expired."))
        XCTAssertEqual(modes[2], .degraded("Sync queue full: new items stay on this device until iCloud returns."))
        XCTAssertEqual(modes[4], .unavailable("no web"))
    }

    func testDurationFormatting() {
        XCTAssertEqual(DegradationPlanner.minutes(-5), "0 min")
        XCTAssertEqual(DegradationPlanner.minutes(Millis.minutes(59)), "59 min")
        XCTAssertEqual(DegradationPlanner.minutes(Millis.minutes(185)), "3 h 5 min")
        XCTAssertEqual(DegradationPlanner.minutes(Millis.hours(52)), "2 d 4 h")
        XCTAssertFalse(DegradationPlanner.minutes(.max).isEmpty)
    }
}
