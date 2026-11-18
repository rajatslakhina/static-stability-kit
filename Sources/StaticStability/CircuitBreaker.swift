/// Tuning for a ``CircuitBreaker``. Every field is clamped into a safe range by the
/// initialiser, so a policy decoded from remote config can never make the breaker
/// divide by zero, overflow, or trip on an empty window.
public struct BreakerPolicy: Sendable, Equatable {
    /// How many recent outcomes the failure rate is computed over (1...10_000).
    public let windowSize: Int
    /// The breaker never opens on fewer outcomes than this (1...windowSize). This is
    /// what makes it probe-driven rather than single-error-driven: one failed
    /// request is noise, five out of ten is an outage.
    public let minimumSamples: Int
    /// Opens when at least this percentage of the window failed (1...100).
    public let failureThresholdPercent: Int
    /// Cooldown after the first trip. Each consecutive re-trip doubles it.
    public let baseCooldownMillis: Int64
    /// Upper bound on the doubled cooldown (≥ baseCooldownMillis).
    public let maxCooldownMillis: Int64
    /// Extra per-client cooldown in `0...cooldownJitterMillis`, so a fleet of clients
    /// that all tripped in the same minute does not probe in the same minute.
    public let cooldownJitterMillis: Int64
    /// Consecutive successful half-open probes needed to close (≥ 1).
    public let halfOpenSuccessesToClose: Int

    public init(
        windowSize: Int = 10,
        minimumSamples: Int = 5,
        failureThresholdPercent: Int = 50,
        baseCooldownMillis: Int64 = Millis.seconds(30),
        maxCooldownMillis: Int64 = Millis.minutes(30),
        cooldownJitterMillis: Int64 = Millis.seconds(30),
        halfOpenSuccessesToClose: Int = 2
    ) {
        let window = min(max(windowSize, 1), 10_000)
        self.windowSize = window
        self.minimumSamples = min(max(minimumSamples, 1), window)
        self.failureThresholdPercent = min(max(failureThresholdPercent, 1), 100)
        let base = max(baseCooldownMillis, 0)
        self.baseCooldownMillis = base
        self.maxCooldownMillis = max(maxCooldownMillis, base)
        // Kept one below Int64.max so `jitter + 1` is always representable.
        self.cooldownJitterMillis = min(max(cooldownJitterMillis, 0), Int64.max - 1)
        self.halfOpenSuccessesToClose = max(halfOpenSuccessesToClose, 1)
    }
}

/// Where a ``CircuitBreaker`` is in its cycle.
public enum BreakerState: Sendable, Equatable {
    /// Requests flow; outcomes are counted.
    case closed
    /// Requests are refused locally until `until`.
    case open(until: Instant)
    /// One probe at a time is allowed through. `successes` counts consecutive passes.
    case halfOpen(successes: Int, probeInFlight: Bool)
}

/// Proof that a ``CircuitBreaker`` admitted one request. Pass it back to
/// ``CircuitBreaker/record(_:success:at:)`` when the request finishes.
///
/// The permit carries the breaker's epoch, which changes on every trip and every
/// half-open probe admission (including the first). A result that comes back under an older epoch (for example a
/// request sent before the trip that times out after the cooldown) is ignored, so it
/// can never be mistaken for the half-open probe's result.
public struct BreakerPermit: Sendable, Equatable {
    public let epoch: UInt64
    /// `true` when this request is the half-open probe.
    public let isProbe: Bool
}

/// What the rest of the app should assume about a dependency right now.
public enum DependencyAvailability: Sendable, Equatable {
    case available
    /// Probing after an outage; treat as unavailable for user-facing decisions.
    case recovering
    case unavailable(retryAfter: Instant)

    public var isAvailable: Bool { self == .available }
}

/// A per-dependency circuit breaker driven by a failure *rate* over a window of
/// recent outcomes, with exponential, jittered cooldown and single-probe half-open.
///
/// Use ``requestPermit(at:)`` and ``record(_:success:at:)`` whenever a request can
/// still be in flight when another one is admitted (any real network call). The
/// Bool pair ``permitsRequest(at:)`` / ``record(success:at:)`` is for callers that
/// record each outcome before admitting the next request, like the replay harness.
///
/// It is a value type with no clock and no locks: callers own it (inside an actor
/// or a single-threaded simulation) and pass `now` in. That keeps every transition
/// deterministic and testable, and keeps the breaker usable from the replay harness
/// with thousands of instances.
public struct CircuitBreaker: Sendable, Equatable {
    public let policy: BreakerPolicy
    public private(set) var state: BreakerState = .closed
    /// Consecutive trips without a full close in between; drives the cooldown doubling.
    public private(set) var consecutiveTrips = 0
    /// Total transitions from not-closed back to closed. The replay uses it as the
    /// recovery epoch so each recovery spreads clients differently.
    public private(set) var recoveries = 0
    /// Changes on every trip and every half-open probe admission (including the
    /// first); see ``BreakerPermit``.
    public private(set) var epoch: UInt64 = 0
    private var window: OutcomeWindow
    private let jitterSeed: UInt64

    public init(policy: BreakerPolicy = BreakerPolicy(), jitterSeed: UInt64 = 0) {
        self.policy = policy
        self.window = OutcomeWindow(capacity: policy.windowSize)
        self.jitterSeed = jitterSeed
    }

    /// Asks to send one request. Returns `nil` when the breaker refuses it locally.
    /// Moves `open` to `halfOpen` once the cooldown has passed, and in `halfOpen`
    /// admits exactly one probe until its outcome is recorded.
    ///
    /// Always record every permit, including on cancellation or an error path
    /// (record `success: false`). A probe whose result is never recorded leaves the
    /// breaker half-open with the probe still "in flight", refusing every request
    /// until the process restarts.
    public mutating func requestPermit(at now: Instant) -> BreakerPermit? {
        guard permitsRequest(at: now) else { return nil }
        if case .halfOpen = state { return BreakerPermit(epoch: epoch, isProbe: true) }
        return BreakerPermit(epoch: epoch, isProbe: false)
    }

    /// Records the outcome of the request `permit` admitted. Results from an earlier
    /// epoch, or that don't match the current state (a normal request's result
    /// arriving while half-open), are ignored. Returns `true` when this outcome closed
    /// a breaker that was not closed.
    @discardableResult
    public mutating func record(_ permit: BreakerPermit, success: Bool, at now: Instant) -> Bool {
        guard permit.epoch == epoch else { return false }
        switch state {
        case .closed where !permit.isProbe, .halfOpen where permit.isProbe:
            return record(success: success, at: now)
        default:
            return false
        }
    }

    /// The Bool form of ``requestPermit(at:)``, for callers that record every
    /// outcome before admitting the next request.
    public mutating func permitsRequest(at now: Instant) -> Bool {
        switch state {
        case .closed:
            return true
        case .open(let until):
            guard now >= until else { return false }
            state = .halfOpen(successes: 0, probeInFlight: true)
            epoch &+= 1
            return true
        case .halfOpen(let successes, let probeInFlight):
            guard !probeInFlight else { return false }
            state = .halfOpen(successes: successes, probeInFlight: true)
            // Each probe gets its own epoch, so a duplicate result from the previous
            // probe can't be counted as this one's.
            epoch &+= 1
            return true
        }
    }

    /// Records the outcome of a request that ``permitsRequest(at:)`` admitted.
    /// Returns `true` when this outcome closed a breaker that was not closed. In
    /// half-open, an outcome is counted only while a probe is in flight.
    @discardableResult
    public mutating func record(success: Bool, at now: Instant) -> Bool {
        switch state {
        case .closed:
            window.append(failure: !success)
            if shouldTrip { trip(at: now) }
            return false
        case .open:
            // A late result from a request sent before the trip. It says nothing
            // about the dependency's health now, so it is ignored.
            return false
        case .halfOpen(let successes, let probeInFlight):
            // No probe out: this result was not admitted by the half-open state.
            guard probeInFlight else { return false }
            guard success else {
                trip(at: now)
                return false
            }
            let passed = Saturating.add(successes, 1)
            guard passed >= policy.halfOpenSuccessesToClose else {
                state = .halfOpen(successes: passed, probeInFlight: false)
                return false
            }
            state = .closed
            window.reset()
            consecutiveTrips = 0
            recoveries = Saturating.add(recoveries, 1)
            return true
        }
    }

    public func availability(at now: Instant) -> DependencyAvailability {
        switch state {
        case .closed: return .available
        case .halfOpen: return .recovering
        case .open(let until): return now >= until ? .recovering : .unavailable(retryAfter: until)
        }
    }

    private var shouldTrip: Bool {
        let count = window.count
        guard count >= policy.minimumSamples, count > 0 else { return false }
        // count ≤ 10_000 and failures ≤ count, so neither product can overflow.
        return window.failures * 100 >= policy.failureThresholdPercent * count
    }

    private mutating func trip(at now: Instant) {
        consecutiveTrips = Saturating.add(consecutiveTrips, 1)
        let doubled = Saturating.doubling(
            policy.baseCooldownMillis,
            times: consecutiveTrips - 1,
            cap: policy.maxCooldownMillis
        )
        let jitterRange = UInt64(policy.cooldownJitterMillis) + 1
        let draw = StableHash.mix(jitterSeed, UInt64(consecutiveTrips)) % jitterRange
        // draw ≤ cooldownJitterMillis < Int64.max, so the conversion is exact.
        let jitter = Int64(draw)
        state = .open(until: now.advanced(byMillis: Saturating.add(doubled, jitter)))
        epoch &+= 1
        window.reset()
    }
}

/// A fixed-capacity ring of recent outcomes with a running failure count.
struct OutcomeWindow: Sendable, Equatable {
    let capacity: Int
    private var slots: [Bool] = []
    private var oldest = 0
    private(set) var failures = 0

    init(capacity: Int) {
        self.capacity = max(capacity, 1)
        slots.reserveCapacity(self.capacity)
    }

    var count: Int { slots.count }

    mutating func append(failure: Bool) {
        guard slots.count >= capacity else {
            slots.append(failure)
            if failure { failures += 1 }
            return
        }
        // Full: overwrite the oldest slot. `oldest` is always kept in 0..<capacity,
        // so this guard is defensive; if it ever failed, the outcome is dropped
        // rather than indexing out of bounds.
        guard slots.indices.contains(oldest) else {
            oldest = 0
            return
        }
        if slots[oldest] { failures -= 1 }
        slots[oldest] = failure
        if failure { failures += 1 }
        oldest = (oldest + 1) % capacity
    }

    mutating func reset() {
        slots.removeAll(keepingCapacity: true)
        oldest = 0
        failures = 0
    }
}
