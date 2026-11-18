import XCTest
@testable import StaticStability

final class ReplayTests: XCTestCase {
    private static let apple = OutageReplay.compare(.apple17Nov2026)
    private static let compound = OutageReplay.compare(.compound)

    private func pick(_ reports: [ReplayReport], _ architecture: ReplayArchitecture,
                      file: StaticString = #filePath, line: UInt = #line) throws -> ReplayReport {
        try XCTUnwrap(reports.first { $0.architecture == architecture }, file: file, line: line)
    }

    /// Guards the draw order: every client consumes the same random numbers each
    /// minute whatever the architecture does, so the workload counters match.
    func testBothArchitecturesDrawTheSameWorkload() throws {
        for reports in [Self.apple, Self.compound] {
            let naive = try pick(reports, .naive), stable = try pick(reports, .staticallyStable)
            XCTAssertEqual(naive.activeUserMinutes, stable.activeUserMinutes)
            XCTAssertEqual(naive.writesMade, stable.writesMade)
            XCTAssertEqual(naive.aiRequests, stable.aiRequests)
            XCTAssertEqual(naive.payingUserMinutes, stable.payingUserMinutes)
        }
    }

    func testEveryWriteIsAccountedFor() throws {
        for report in Self.apple + Self.compound {
            XCTAssertEqual(
                report.writesMade,
                report.writesSynced + report.writesLost + report.writesRejectedFull + report.writesPendingAtEnd,
                "\(report.architecture)"
            )
            XCTAssertEqual(report.aiRequests, report.aiServedFull + report.aiServedReduced + report.aiFailed)
        }
    }

    func testNaiveArchitectureFailsUsersDuringTheOutage() throws {
        let naive = try pick(Self.apple, .naive)
        XCTAssertGreaterThan(naive.signedOutUserMinutes, naive.activeUserMinutes / 3, "signed out for the outage")
        XCTAssertGreaterThan(naive.lockedOutPayingUserMinutes, 0)
        XCTAssertGreaterThan(naive.writesLost, naive.writesMade / 10)
        XCTAssertEqual(naive.falseGrantUserMinutes, 0)
    }

    func testStaticallyStableKeepsUsersWorking() throws {
        let stable = try pick(Self.apple, .staticallyStable)
        XCTAssertEqual(stable.signedOutUserMinutes, 0)
        XCTAssertEqual(stable.lockedOutPayingUserMinutes, 0)
        XCTAssertEqual(stable.writesLost, 0)
        XCTAssertEqual(stable.writesPendingAtEnd, 0, "the backlog fully drains after recovery")
        XCTAssertEqual(stable.sessionContinuityPercent, 100)
        XCTAssertEqual(stable.entitlementAccuracyPercent, 100)
    }

    func testGraceHasAVisibleBoundedCost() throws {
        let naive = try pick(Self.apple, .naive), stable = try pick(Self.apple, .staticallyStable)
        XCTAssertGreaterThan(stable.falseGrantUserMinutes, 0, "cancelled users whose expiry falls inside the outage keep access")
        XCTAssertLessThan(stable.falseGrantUserMinutes * 5, naive.lockedOutPayingUserMinutes)
    }

    func testBreakersCutLoadOnDownDependenciesAndTheGateFlattensRecovery() throws {
        let naive = try pick(Self.apple, .naive), stable = try pick(Self.apple, .staticallyStable)
        XCTAssertLessThan(stable.requestsToDownDependencies * 4, naive.requestsToDownDependencies)
        XCTAssertLessThan(stable.peakSyncRequestsPerMinute * 2, naive.peakSyncRequestsPerMinute)
    }

    func testCompoundOutageAnswersMoreAIRequestsThanNaive() throws {
        let naive = try pick(Self.compound, .naive), stable = try pick(Self.compound, .staticallyStable)
        XCTAssertGreaterThan(naive.aiFailed, 0)
        XCTAssertEqual(naive.aiServedReduced, 0)
        XCTAssertGreaterThan(stable.aiServedReduced, 0)
        XCTAssertLessThan(stable.aiFailed * 2, naive.aiFailed)
        XCTAssertGreaterThan(stable.aiServedPercent, naive.aiServedPercent)
    }

    func testReplayIsReproducibleAcrossProcesses() throws {
        // Golden values recorded from an earlier run. Anything per-process (Hasher,
        // dictionary iteration order leaking into the workload) breaks these.
        let naive = try pick(Self.apple, .naive), stable = try pick(Self.apple, .staticallyStable)
        XCTAssertEqual(naive.activeUserMinutes, 107_880)
        XCTAssertEqual(naive.writesMade, 21_626)
        XCTAssertEqual(naive.writesLost, 7_935)
        XCTAssertEqual(naive.lockedOutPayingUserMinutes, 3_179)
        XCTAssertEqual(naive.peakSyncRequestsPerMinute, 1_042)
        XCTAssertEqual(stable.falseGrantUserMinutes, 219)
        XCTAssertEqual(stable.peakSyncRequestsPerMinute, 336)
        XCTAssertEqual(stable.requestsToDownDependencies, 35_901)
    }

    func testCompoundGoldenValuesQuotedInTheREADME() throws {
        let naive = try pick(Self.compound, .naive), stable = try pick(Self.compound, .staticallyStable)
        XCTAssertEqual(naive.aiServedFull, 12_239)
        XCTAssertEqual(naive.aiFailed, 4_044)
        XCTAssertEqual(stable.aiServedFull, 12_140)
        XCTAssertEqual(stable.aiServedReduced, 2_713)
        XCTAssertEqual(stable.aiFailed, 1_430)
        XCTAssertEqual(naive.aiServedFull - stable.aiServedFull, 99)
        XCTAssertEqual(String(format: "%.1f", naive.aiServedPercent), "75.2")
        XCTAssertEqual(String(format: "%.1f", stable.aiServedPercent), "91.2")
    }

    func testWithoutAnOutageTheArchitecturesLookTheSameToUsers() throws {
        let calm = OutageScenario(id: "calm", title: "Calm", summary: "", durationMinutes: 240, windows: [])
        for report in OutageReplay.compare(calm) {
            XCTAssertEqual(report.signedOutUserMinutes, 0)
            XCTAssertEqual(report.lockedOutPayingUserMinutes, 0)
            XCTAssertEqual(report.falseGrantUserMinutes, 0)
            XCTAssertEqual(report.writesLost, 0)
            XCTAssertEqual(report.requestsToDownDependencies, 0)
            XCTAssertEqual(report.aiFailed, 0)
        }
    }

    // MARK: - Each component earns its metric: break it and the metric regresses.

    func testRemovingTheGraceLocksPayingUsersOut() throws {
        let noGrace = OutageReplay.run(.apple17Nov2026, architecture: .staticallyStable,
                                       config: ReplayConfig(outageGraceMillis: 0))
        XCTAssertGreaterThan(noGrace.lockedOutPayingUserMinutes, 0)
        XCTAssertEqual(noGrace.falseGrantUserMinutes, 0)
    }

    func testRemovingTheRecoveryGateRaisesThePeak() throws {
        let stable = try pick(Self.apple, .staticallyStable)
        let ungated = OutageReplay.run(.apple17Nov2026, architecture: .staticallyStable,
                                       config: ReplayConfig(recoveryWindowMinutes: 0, pushesPerMinute: 10_000, pushBurst: 10_000))
        XCTAssertGreaterThan(ungated.peakSyncRequestsPerMinute, stable.peakSyncRequestsPerMinute * 2)
        // Golden values quoted in the README's recovery-gate trade-off.
        XCTAssertEqual(ungated.peakSyncRequestsPerMinute, 690)
        XCTAssertEqual(ungated.maxUnsyncedWriteAgeMinutes, 206)
        XCTAssertEqual(stable.maxUnsyncedWriteAgeMinutes, 225)
    }

    func testNaiveOldestWriteWithoutProcessKills() {
        // The README notes the naive 182 would be 195 if the process were never killed.
        let neverKilled = OutageReplay.run(.apple17Nov2026, architecture: .naive, config: ReplayConfig(terminationPercent: 0))
        XCTAssertEqual(neverKilled.writesLost, 0)
        XCTAssertEqual(neverKilled.maxUnsyncedWriteAgeMinutes, 195)
    }

    func testATinyOutboxBackpressuresInsteadOfLosingWrites() throws {
        let tiny = OutageReplay.run(.apple17Nov2026, architecture: .staticallyStable,
                                    config: ReplayConfig(outboxCapacity: 2))
        XCTAssertGreaterThan(tiny.writesRejectedFull, 0)
        XCTAssertEqual(tiny.writesLost, 0)
    }

    func testHostileConfigIsClamped() {
        let config = ReplayConfig(clients: -5, activePercent: 900, writePercent: -1, renewalSpreadMinutes: 0,
                                  outboxCapacity: -9, recoveryWindowMinutes: -3)
        XCTAssertEqual(config.clients, 1)
        XCTAssertEqual(config.activePercent, 100)
        XCTAssertEqual(config.writePercent, 0)
        XCTAssertEqual(config.renewalSpreadMinutes, 1)
        XCTAssertEqual(config.outboxCapacity, 0)
        XCTAssertEqual(config.recoveryWindowMinutes, 0)
        let report = OutageReplay.run(.apple17Nov2026, architecture: .staticallyStable, config: config)
        XCTAssertEqual(report.activeUserMinutes, 360)
    }

    func testScenarioWindowsAndPercentages() {
        let scenario = OutageScenario.apple17Nov2026
        XCTAssertTrue(scenario.isUp(.identity, atMinute: 29))
        XCTAssertFalse(scenario.isUp(.identity, atMinute: 30))
        XCTAssertFalse(scenario.isUp(.identity, atMinute: 209))
        XCTAssertTrue(scenario.isUp(.identity, atMinute: 210))
        XCTAssertTrue(scenario.isUp(.cloudAI, atMinute: 100))
        XCTAssertFalse(OutageScenario.compound.isUp(.cloudAI, atMinute: 100))
        XCTAssertFalse(OutageScenario.compound.isUp(.remoteConfig, atMinute: 179))
        XCTAssertTrue(OutageScenario.compound.isUp(.remoteConfig, atMinute: 180))
        XCTAssertTrue(OutageScenario.apple17Nov2026.isUp(.remoteConfig, atMinute: 100))
        XCTAssertEqual(scenario.lastRecoveryMinute, 210)
        let inverted = OutageWindow(dependency: .identity, startMinute: 50, endMinute: 10)
        XCTAssertEqual(inverted.endMinute, 50, "an inverted window is empty, not negative")
        XCTAssertEqual(ReplayReport.percent(5, of: 0), 100)
        XCTAssertEqual(ReplayReport.percent(-5, of: 10), 0)
    }
}
