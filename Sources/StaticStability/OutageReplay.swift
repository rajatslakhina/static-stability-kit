/// One dependency being down for `startMinute ..< endMinute` of a replay.
public struct OutageWindow: Sendable, Equatable {
    public let dependency: Dependency
    public let startMinute: Int
    public let endMinute: Int

    public init(dependency: Dependency, startMinute: Int, endMinute: Int) {
        self.dependency = dependency
        self.startMinute = max(startMinute, 0)
        self.endMinute = max(endMinute, self.startMinute)
    }
}

/// A scripted fault-injection timeline.
public struct OutageScenario: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let summary: String
    public let durationMinutes: Int
    public let windows: [OutageWindow]

    public init(id: String, title: String, summary: String, durationMinutes: Int, windows: [OutageWindow]) {
        self.id = id
        self.title = title
        self.summary = summary
        // One day at most: a replay allocates per-minute arrays and steps every client
        // every minute, so the bounds keep a hostile scenario from exhausting memory.
        self.durationMinutes = min(max(durationMinutes, 1), 24 * 60)
        self.windows = windows
    }

    public func isUp(_ dependency: Dependency, atMinute minute: Int) -> Bool {
        !windows.contains { $0.dependency == dependency && minute >= $0.startMinute && minute < $0.endMinute }
    }

    /// Minute at which the last window closes (0 if there are none).
    public var lastRecoveryMinute: Int { windows.map(\.endMinute).max() ?? 0 }

    /// Modelled on the 17 Nov 2026 Apple outage, when Apple Account sign-in, Sign in
    /// with Apple, the App Store and iCloud were down together for hours. The
    /// three-hour length and the simultaneous start and end are illustrative, not a
    /// measured timeline.
    public static let apple17Nov2026 = OutageScenario(
        id: "apple-17-nov",
        title: "Apple, 17 Nov",
        summary: "Sign in with Apple, the App Store and iCloud down together for 3 hours.",
        durationMinutes: 360,
        windows: [
            OutageWindow(dependency: .identity, startMinute: 30, endMinute: 210),
            OutageWindow(dependency: .storeKit, startMinute: 30, endMinute: 210),
            OutageWindow(dependency: .cloudSync, startMinute: 30, endMinute: 210),
        ]
    )

    /// The same outage with the cloud AI provider failing for 90 minutes and the
    /// remote-config service for 2 hours inside it, so the AI fallback and the
    /// last-known-good config paths are exercised too. (The replay's metrics do not
    /// model config; the demo's posture screen shows it.)
    public static let compound = OutageScenario(
        id: "compound",
        title: "Compound",
        summary: "The Apple outage, plus cloud AI down for 90 minutes and remote config down for 2 hours inside it.",
        durationMinutes: 360,
        windows: apple17Nov2026.windows + [
            OutageWindow(dependency: .cloudAI, startMinute: 60, endMinute: 150),
            OutageWindow(dependency: .remoteConfig, startMinute: 60, endMinute: 180),
        ]
    )

    public static let all: [OutageScenario] = [.apple17Nov2026, .compound]
}

/// The two client designs the replay compares.
public enum ReplayArchitecture: String, Sendable, CaseIterable, Identifiable {
    /// Common, reasonable-looking choices for each dependency taken one at a time:
    /// sign out on a failed credential check, trust the receipt only until expiry,
    /// retry the in-memory write queue on every foreground minute, cloud-only AI.
    case naive
    /// The components in this package wired together.
    case staticallyStable

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .naive: return "Naive"
        case .staticallyStable: return "Statically stable"
        }
    }
}

/// Population and policy parameters for a replay. Clamped so no setting can make
/// the simulation trap; the largest allowed replay (5,000 clients, 1,440 minutes)
/// takes seconds on a laptop, so on a phone keep runs near the defaults.
public struct ReplayConfig: Sendable, Equatable {
    public let clients: Int
    public let seed: UInt64
    /// Chance a client is in the foreground in a given minute.
    public let activePercent: Int
    /// Chance an active client makes a write in a given minute.
    public let writePercent: Int
    /// Chance an active client uses an AI feature in a given minute.
    public let aiPercent: Int
    /// Chance the app process is killed in a given minute (memory pressure, the
    /// user swiping it away). An in-memory queue loses its writes when this happens.
    public let terminationPercent: Int
    /// Subscribers who cancelled; their entitlement really does end at expiry.
    public let cancelledPercent: Int
    /// Verified expiries are spread uniformly over this many minutes from the start.
    /// Real monthly renewals spread over ~43,200 minutes; the replay concentrates
    /// them so the effect of a 3-hour outage is visible in a 1,000-client run.
    public let renewalSpreadMinutes: Int
    public let outboxCapacity: Int
    public let recoveryWindowMinutes: Int
    public let pushesPerMinute: Int
    public let pushBurst: Int
    public let outageGraceMillis: Int64
    public let maxUnverifiedSessionMillis: Int64
    public let breakerPolicy: BreakerPolicy

    public init(
        clients: Int = 1_000,
        seed: UInt64 = 17,
        activePercent: Int = 30,
        writePercent: Int = 20,
        aiPercent: Int = 15,
        terminationPercent: Int = 2,
        cancelledPercent: Int = 5,
        renewalSpreadMinutes: Int = 1_440,
        outboxCapacity: Int = 200,
        recoveryWindowMinutes: Int = 30,
        pushesPerMinute: Int = 1,
        pushBurst: Int = 2,
        outageGraceMillis: Int64 = Millis.hours(48),
        maxUnverifiedSessionMillis: Int64 = Millis.days(7),
        breakerPolicy: BreakerPolicy = BreakerPolicy(
            windowSize: 6,
            minimumSamples: 3,
            failureThresholdPercent: 50,
            baseCooldownMillis: Millis.minutes(2),
            maxCooldownMillis: Millis.minutes(16),
            cooldownJitterMillis: Millis.minutes(4),
            halfOpenSuccessesToClose: 2
        )
    ) {
        func percent(_ value: Int) -> Int { min(max(value, 0), 100) }
        // 5,000 clients × 1,440 minutes is the largest replay: bounded in time and
        // memory even for the naive design's unbounded per-client queue.
        self.clients = min(max(clients, 1), 5_000)
        self.seed = seed
        self.activePercent = percent(activePercent)
        self.writePercent = percent(writePercent)
        self.aiPercent = percent(aiPercent)
        self.terminationPercent = percent(terminationPercent)
        self.cancelledPercent = percent(cancelledPercent)
        self.renewalSpreadMinutes = min(max(renewalSpreadMinutes, 1), 60 * 24 * 365)
        self.outboxCapacity = min(max(outboxCapacity, 0), 100_000)
        self.recoveryWindowMinutes = min(max(recoveryWindowMinutes, 0), 24 * 60)
        self.pushesPerMinute = min(max(pushesPerMinute, 0), 10_000)
        self.pushBurst = min(max(pushBurst, 0), 10_000)
        self.outageGraceMillis = max(outageGraceMillis, 0)
        self.maxUnverifiedSessionMillis = max(maxUnverifiedSessionMillis, 0)
        self.breakerPolicy = breakerPolicy
    }
}

/// User-visible outcomes of one replay. Counts are in user-minutes: one client in
/// the foreground for one minute.
public struct ReplayReport: Sendable, Equatable {
    public let scenarioID: String
    public let architecture: ReplayArchitecture
    public internal(set) var activeUserMinutes = 0
    /// Foreground minutes spent signed out.
    public internal(set) var signedOutUserMinutes = 0
    /// Foreground minutes of users who really are entitled.
    public internal(set) var payingUserMinutes = 0
    /// Foreground minutes in which an entitled user was denied premium features.
    public internal(set) var lockedOutPayingUserMinutes = 0
    /// Foreground minutes in which a user who had cancelled was still granted access.
    /// The cost of the outage grace, reported rather than hidden.
    public internal(set) var falseGrantUserMinutes = 0
    public internal(set) var writesMade = 0
    public internal(set) var writesSynced = 0
    /// Writes in an in-memory queue when the process was killed.
    public internal(set) var writesLost = 0
    /// Writes refused by a full outbox (the user was told; nothing was lost silently).
    public internal(set) var writesRejectedFull = 0
    /// Writes still pending when the replay ended.
    public internal(set) var writesPendingAtEnd = 0
    /// Oldest unsynced write seen at any minute, among writes that were not lost.
    public internal(set) var maxUnsyncedWriteAgeMinutes = 0
    /// Every request sent to a dependency while it was down: wasted load and battery.
    public internal(set) var requestsToDownDependencies = 0
    /// Sync pushes (including breaker probes) per minute, for the recovery chart.
    public internal(set) var syncRequestsPerMinute: [Int] = []
    public internal(set) var aiRequests = 0
    public internal(set) var aiServedFull = 0
    public internal(set) var aiServedReduced = 0
    public internal(set) var aiFailed = 0

    public var peakSyncRequestsPerMinute: Int { syncRequestsPerMinute.max() ?? 0 }

    /// Share of foreground minutes with a usable session, 0...100.
    public var sessionContinuityPercent: Double {
        Self.percent(Saturating.add(activeUserMinutes, -signedOutUserMinutes), of: activeUserMinutes)
    }

    /// Share of entitled users' foreground minutes in which they had access, 0...100.
    public var entitlementAccuracyPercent: Double {
        Self.percent(Saturating.add(payingUserMinutes, -lockedOutPayingUserMinutes), of: payingUserMinutes)
    }

    /// Share of AI requests that got an answer (full or reduced), 0...100.
    public var aiServedPercent: Double {
        Self.percent(Saturating.add(aiServedFull, aiServedReduced), of: aiRequests)
    }

    static func percent(_ part: Int, of whole: Int) -> Double {
        guard whole > 0 else { return 100 }
        return Double(min(max(part, 0), whole)) * 100 / Double(whole)
    }
}

/// A deterministic, minute-by-minute replay of an outage over a simulated fleet.
///
/// Both architectures see exactly the same workload: each client draws the same
/// random numbers in the same order every minute whatever the architecture does
/// with them, so every difference in the report comes from the design.
///
/// What is modelled and what is not: sessions, entitlements, breakers, recovery
/// gating and AI routing run the real types from this package. The sync queue is
/// modelled as a list of enqueue minutes per client; the real ``DurableOutbox``
/// (persistence, coalescing, actor reentrancy) is covered by its own tests, not by
/// this replay. Network latency, partial failures and server capacity are not
/// modelled: a dependency is simply up or down each minute.
public enum OutageReplay {
    public static let aiTasks: [AITask] = [
        AITask(name: "Draft reply", required: [.shortRewrite], preferred: [.toolUse]),
        AITask(name: "Summarize thread", required: [.extraction], preferred: [.longContextSummary]),
        AITask(name: "Ask with sources", required: [.webGrounding]),
    ]

    public static func compare(_ scenario: OutageScenario, config: ReplayConfig = ReplayConfig()) -> [ReplayReport] {
        ReplayArchitecture.allCases.map { run(scenario, architecture: $0, config: config) }
    }

    public static func run(
        _ scenario: OutageScenario,
        architecture: ReplayArchitecture,
        config: ReplayConfig = ReplayConfig()
    ) -> ReplayReport {
        var report = ReplayReport(scenarioID: scenario.id, architecture: architecture)
        report.syncRequestsPerMinute = [Int](repeating: 0, count: scenario.durationMinutes)
        var clients = (0..<config.clients).map { Client(index: $0, config: config) }
        let entitlementPolicy = EntitlementPolicy(outageGraceMillis: config.outageGraceMillis)
        let router = CapabilityRouter()

        for minute in 0..<scenario.durationMinutes {
            let now = Instant.minute(minute)
            for i in clients.indices {
                clients[i].step(
                    minute: minute,
                    now: now,
                    scenario: scenario,
                    architecture: architecture,
                    config: config,
                    entitlementPolicy: entitlementPolicy,
                    router: router,
                    report: &report
                )
            }
        }
        report.writesPendingAtEnd = clients.reduce(0) { Saturating.add($0, $1.pending.count) }
        return report
    }
}

/// One simulated installation.
private struct Client {
    static let renewalPeriod = Millis.days(30)

    let installationID: String
    var rng: SplitMix64
    let cancelled: Bool
    /// Ground truth: when the subscription the user started with ends if not renewed.
    let originalExpiry: Instant
    /// What the device has verified so far.
    var verifiedExpiry: Instant
    /// Last successful refresh from the store (the entitlement's `verifiedAt`).
    var lastRefresh: Instant
    // Naive state
    var naiveSignedIn = true
    // Statically stable state
    var session: SessionContinuity
    var breakers: [Dependency: CircuitBreaker]
    var gate: RecoveryGate
    /// Enqueue minute of each pending write, oldest first.
    var pending: [Int] = []

    init(index: Int, config: ReplayConfig) {
        installationID = "client-\(index)"
        var rng = SplitMix64(seed: StableHash.mix(config.seed, UInt64(truncatingIfNeeded: index)))
        cancelled = rng.chance(percent: config.cancelledPercent)
        let expiry = Instant.minute(rng.below(config.renewalSpreadMinutes))
        originalExpiry = expiry
        verifiedExpiry = expiry
        lastRefresh = .minute(-1)
        session = SessionContinuity(
            maxUnverifiedMillis: config.maxUnverifiedSessionMillis,
            lastVerifiedAt: Instant.minute(-rng.below(24 * 60))
        )
        let idHash = StableHash.fnv1a64(installationID)
        var breakers: [Dependency: CircuitBreaker] = [:]
        for (offset, dependency) in Dependency.allCases.enumerated() {
            breakers[dependency] = CircuitBreaker(
                policy: config.breakerPolicy,
                jitterSeed: StableHash.mix(idHash, UInt64(offset))
            )
        }
        self.breakers = breakers
        gate = RecoveryGate(
            installationID: installationID,
            jitter: RecoveryJitter(windowMillis: Millis.minutes(Int64(config.recoveryWindowMinutes))),
            bucket: TokenBucket(
                capacity: Int64(config.pushBurst),
                refillPerMinute: Int64(config.pushesPerMinute),
                tokens: Int64(config.pushBurst),
                at: .minute(0)
            )
        )
        self.rng = rng
    }

    func trulyEntitled(at now: Instant) -> Bool {
        !cancelled || now < originalExpiry
    }

    mutating func step(
        minute: Int,
        now: Instant,
        scenario: OutageScenario,
        architecture: ReplayArchitecture,
        config: ReplayConfig,
        entitlementPolicy: EntitlementPolicy,
        router: CapabilityRouter,
        report: inout ReplayReport
    ) {
        // Same draws in the same order for both architectures.
        let active = rng.chance(percent: config.activePercent)
        let writes = rng.chance(percent: config.writePercent)
        let asksAI = rng.chance(percent: config.aiPercent)
        let taskIndex = rng.below(OutageReplay.aiTasks.count)
        let killed = rng.chance(percent: config.terminationPercent)

        if active {
            report.activeUserMinutes += 1
            stepIdentity(now: now, minute: minute, scenario: scenario, architecture: architecture, report: &report)
            stepEntitlement(now: now, minute: minute, scenario: scenario, architecture: architecture,
                            policy: entitlementPolicy, report: &report)
            if writes {
                report.writesMade += 1
                if architecture == .naive || pending.count < config.outboxCapacity {
                    pending.append(minute)
                } else {
                    report.writesRejectedFull += 1
                }
            }
            stepSync(now: now, minute: minute, scenario: scenario, architecture: architecture, report: &report)
            if asksAI, OutageReplay.aiTasks.indices.contains(taskIndex) {
                stepAI(OutageReplay.aiTasks[taskIndex], now: now, minute: minute, scenario: scenario,
                       architecture: architecture, router: router, report: &report)
            }
        }

        if let oldest = pending.first {
            report.maxUnsyncedWriteAgeMinutes = max(report.maxUnsyncedWriteAgeMinutes, minute - oldest)
        }
        // The naive queue lives in memory; the outbox is durable and survives.
        if killed, architecture == .naive, !pending.isEmpty {
            report.writesLost = Saturating.add(report.writesLost, pending.count)
            pending.removeAll()
        }
    }

    /// Sends one request through the breaker for `dependency`. Returns `nil` when the
    /// breaker refused locally, otherwise whether the request succeeded.
    private mutating func guardedRequest(
        _ dependency: Dependency,
        now: Instant,
        minute: Int,
        scenario: OutageScenario,
        report: inout ReplayReport
    ) -> (succeeded: Bool, recovered: Bool)? {
        guard var breaker = breakers[dependency], breaker.permitsRequest(at: now) else { return nil }
        let up = scenario.isUp(dependency, atMinute: minute)
        if !up { report.requestsToDownDependencies += 1 }
        let recovered = breaker.record(success: up, at: now)
        breakers[dependency] = breaker
        return (up, recovered)
    }

    private func breakerClosed(_ dependency: Dependency) -> Bool {
        breakers[dependency]?.state == .closed
    }

    private mutating func stepIdentity(
        now: Instant, minute: Int, scenario: OutageScenario,
        architecture: ReplayArchitecture, report: inout ReplayReport
    ) {
        let up = scenario.isUp(.identity, atMinute: minute)
        switch architecture {
        case .naive:
            // Credential check when signed in, sign-in attempt when not. Either way a
            // request; a failed check is treated as signed out.
            if !up { report.requestsToDownDependencies += 1 }
            naiveSignedIn = up
            if !naiveSignedIn { report.signedOutUserMinutes += 1 }
        case .staticallyStable:
            let decision: SessionDecision
            if let result = guardedRequest(.identity, now: now, minute: minute, scenario: scenario, report: &report) {
                decision = session.evaluate(result.succeeded ? .authorized : .unavailable, at: now)
            } else {
                decision = session.decisionWithoutProvider(at: now)
            }
            if !decision.hasSession { report.signedOutUserMinutes += 1 }
        }
    }

    private mutating func refreshTransactions(at now: Instant) {
        lastRefresh = now
        // The store renews every subscriber who did not cancel; a refresh that
        // reaches it sees the renewal.
        guard !cancelled else { return }
        while verifiedExpiry <= now {
            verifiedExpiry = verifiedExpiry.advanced(byMillis: Self.renewalPeriod)
        }
    }

    private mutating func stepEntitlement(
        now: Instant, minute: Int, scenario: OutageScenario,
        architecture: ReplayArchitecture, policy: EntitlementPolicy, report: inout ReplayReport
    ) {
        let granted: Bool
        switch architecture {
        case .naive:
            let up = scenario.isUp(.storeKit, atMinute: minute)
            if up { refreshTransactions(at: now) } else { report.requestsToDownDependencies += 1 }
            granted = now < verifiedExpiry
        case .staticallyStable:
            let result = guardedRequest(.storeKit, now: now, minute: minute, scenario: scenario, report: &report)
            // Reachable means this minute's refresh actually reached the store, so an
            // expiry it confirms is real. A refused or failed refresh is unreachable.
            let reachable = result?.succeeded == true
            if reachable { refreshTransactions(at: now) }
            let entitlement = VerifiedEntitlement(productID: "pro.monthly", expiresAt: verifiedExpiry,
                                                  verifiedAt: lastRefresh)
            granted = policy.decide(entitlement, storeReachable: reachable, at: now).isGranted
        }
        if trulyEntitled(at: now) {
            report.payingUserMinutes += 1
            if !granted { report.lockedOutPayingUserMinutes += 1 }
        } else if granted {
            report.falseGrantUserMinutes += 1
        }
    }

    private mutating func stepSync(
        now: Instant, minute: Int, scenario: OutageScenario,
        architecture: ReplayArchitecture, report: inout ReplayReport
    ) {
        guard !pending.isEmpty, report.syncRequestsPerMinute.indices.contains(minute) else { return }
        let up = scenario.isUp(.cloudSync, atMinute: minute)
        switch architecture {
        case .naive:
            // Retry the whole queue, one request per write, every foreground minute.
            let count = pending.count
            report.syncRequestsPerMinute[minute] = Saturating.add(report.syncRequestsPerMinute[minute], count)
            if up {
                report.writesSynced = Saturating.add(report.writesSynced, count)
                pending.removeAll()
            } else {
                report.requestsToDownDependencies = Saturating.add(report.requestsToDownDependencies, count)
            }
        case .staticallyStable:
            while !pending.isEmpty {
                // Normal traffic goes through the recovery gate; breaker probes
                // (open or half-open) are rate-limited by the breaker itself.
                if breakerClosed(.cloudSync), !gate.mayPush(at: now) { break }
                guard let result = guardedRequest(.cloudSync, now: now, minute: minute, scenario: scenario,
                                                  report: &report) else { break }
                report.syncRequestsPerMinute[minute] = Saturating.add(report.syncRequestsPerMinute[minute], 1)
                guard result.succeeded else { break }
                pending.removeFirst()
                report.writesSynced = Saturating.add(report.writesSynced, 1)
                if result.recovered, let epoch = breakers[.cloudSync]?.recoveries {
                    gate.dependencyRecovered(at: now, epoch: epoch)
                }
            }
        }
    }

    private mutating func stepAI(
        _ task: AITask, now: Instant, minute: Int, scenario: OutageScenario,
        architecture: ReplayArchitecture, router: CapabilityRouter, report: inout ReplayReport
    ) {
        report.aiRequests += 1
        switch architecture {
        case .naive:
            if scenario.isUp(.cloudAI, atMinute: minute) {
                report.aiServedFull += 1
            } else {
                report.requestsToDownDependencies += 1
                report.aiFailed += 1
            }
        case .staticallyStable:
            if let result = guardedRequest(.cloudAI, now: now, minute: minute, scenario: scenario, report: &report),
               result.succeeded {
                report.aiServedFull += 1
                return
            }
            // Cloud refused locally or failed: route without it.
            switch router.route(task, isAvailable: { $0 != .cloud }) {
            case .full: report.aiServedFull += 1
            case .reduced: report.aiServedReduced += 1
            case .unavailable: report.aiFailed += 1
            }
        }
    }
}
