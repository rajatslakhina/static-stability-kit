/// Spreads a fleet of clients across a recovery window, deterministically.
///
/// When a dependency comes back, every client that queued work during the outage
/// wants to sync at once. If they all notice within the same minute, the recovered
/// service takes a spike of the whole fleet's backlog and can fall over again. Each
/// client instead waits a delay derived from its installation ID and the recovery
/// epoch: stable across relaunches (so killing the app does not reroll the dice),
/// different per recovery (so the same device is not always last).
public struct RecoveryJitter: Sendable, Equatable {
    public let windowMillis: Int64

    public init(windowMillis: Int64 = Millis.minutes(30)) {
        self.windowMillis = max(windowMillis, 0)
    }

    /// A delay in `0..<windowMillis` (0 when the window is empty).
    public func delayMillis(installationID: String, recoveryEpoch: Int) -> Int64 {
        guard windowMillis > 0 else { return 0 }
        let hash = StableHash.mix(StableHash.fnv1a64(installationID), UInt64(truncatingIfNeeded: recoveryEpoch))
        // The remainder is below windowMillis ≤ Int64.max, so it converts exactly.
        return Int64(hash % UInt64(windowMillis))
    }
}

/// A token bucket in integer arithmetic that does not lose fractional refill.
///
/// The naive version computes `elapsed * rate / 60_000` and resets its timestamp on
/// every call, which discards the remainder: a client that checks every 10 seconds
/// with a rate of 1 per minute never earns a token. This keeps the remainder.
public struct TokenBucket: Sendable, Equatable {
    public let capacity: Int64
    public let refillPerMinute: Int64
    public private(set) var tokens: Int64
    private var lastRefill: Instant
    /// Refill progress below one whole token, in token·milliseconds per minute.
    private var carry: Int64 = 0

    public init(capacity: Int64, refillPerMinute: Int64, tokens: Int64 = 0, at now: Instant) {
        self.capacity = max(capacity, 0)
        self.refillPerMinute = max(refillPerMinute, 0)
        self.tokens = min(max(tokens, 0), self.capacity)
        self.lastRefill = now
    }

    /// Takes one token if available.
    public mutating func tryTake(at now: Instant) -> Bool {
        refill(at: now)
        guard tokens > 0 else { return false }
        tokens -= 1
        return true
    }

    private mutating func refill(at now: Instant) {
        // A clock moved backwards earns nothing and does not move the reference.
        guard now > lastRefill else { return }
        let elapsed = now.millis(since: lastRefill)
        lastRefill = now
        guard tokens < capacity else {
            carry = 0
            return
        }
        let units = Saturating.add(Saturating.multiply(elapsed, refillPerMinute), carry)
        let whole = units / 60_000
        carry = units % 60_000
        tokens = min(Saturating.add(tokens, whole), capacity)
        if tokens >= capacity { carry = 0 }
    }
}

/// Decides when a client may send recovery traffic: not before its jittered slot,
/// and then no faster than its token bucket allows.
public struct RecoveryGate: Sendable, Equatable {
    public let installationID: String
    public let jitter: RecoveryJitter
    private var bucket: TokenBucket
    public private(set) var notBefore: Instant?

    public init(installationID: String, jitter: RecoveryJitter, bucket: TokenBucket) {
        self.installationID = installationID
        self.jitter = jitter
        self.bucket = bucket
    }

    /// Call when the dependency's breaker closes after an outage.
    public mutating func dependencyRecovered(at now: Instant, epoch: Int) {
        notBefore = now.advanced(byMillis: jitter.delayMillis(installationID: installationID, recoveryEpoch: epoch))
    }

    /// Whether one more push may go out now. Consumes a token when it says yes.
    public mutating func mayPush(at now: Instant) -> Bool {
        if let slot = notBefore {
            guard now >= slot else { return false }
            notBefore = nil
        }
        return bucket.tryTake(at: now)
    }
}

extension RecoveryJitter {
    /// Whether `delays` fill `windowMillis` roughly evenly: the window is split into
    /// `buckets` slices (1...10_000; anything else returns `false`) and every slice
    /// must hold within `tolerancePercent` of the mean.
    /// Public so an app can check its own fleet's spread in a test.
    public static func isRoughlyUniform(delays: [Int64], windowMillis: Int64, buckets: Int, tolerancePercent: Int) -> Bool {
        // `buckets` sizes an allocation, so it is capped: a hostile value cannot
        // exhaust memory or trap.
        guard windowMillis > 0, (1...10_000).contains(buckets), !delays.isEmpty else { return false }
        var counts = [Int](repeating: 0, count: buckets)
        for delay in delays {
            guard delay >= 0, delay < windowMillis else { return false }
            // delay < windowMillis, so the slice index is in 0..<buckets.
            let slice = Int(Saturating.multiply(delay, Int64(buckets)) / windowMillis)
            guard counts.indices.contains(slice) else { return false }
            counts[slice] += 1
        }
        let mean = Double(delays.count) / Double(buckets)
        let allowed = mean * Double(min(max(tolerancePercent, 0), 100)) / 100
        return counts.allSatisfy { abs(Double($0) - mean) <= allowed }
    }
}
