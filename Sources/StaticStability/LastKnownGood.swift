/// How long a fetched config counts as fresh, and how long a stale one may be served.
public struct StalenessPolicy: Sendable, Equatable {
    /// Younger than this is `.fresh` (clamped to ≥ 0).
    public let freshForMillis: Int64
    /// Older than this falls back to the bundled default. `nil` means "serve the
    /// last-known-good value forever": the statically stable choice, because an
    /// outage of the config service should never change app behaviour.
    public let maxStaleMillis: Int64?

    public init(freshForMillis: Int64 = Millis.minutes(15), maxStaleMillis: Int64? = nil) {
        let fresh = max(freshForMillis, 0)
        self.freshForMillis = fresh
        self.maxStaleMillis = maxStaleMillis.map { max($0, fresh) }
    }
}

/// Where a served config value came from.
public enum ConfigProvenance: Sendable, Equatable {
    case fresh(ageMillis: Int64)
    case lastKnownGood(ageMillis: Int64)
    case bundledDefault(BundledReason)
}

public enum BundledReason: Sendable, Equatable {
    case neverFetched
    case tooStale(ageMillis: Int64)
}

public struct ServedConfig<Value: Sendable & Equatable>: Sendable, Equatable {
    public let value: Value
    public let provenance: ConfigProvenance
}

/// Why ``LastKnownGood/offer(_:fetchedAt:isValid:)`` did or did not take a value.
public enum OfferOutcome: Sendable, Equatable {
    case accepted
    /// The value failed validation. The previous good value is kept: a bad push
    /// from the config service must not overwrite a config that works.
    case rejectedInvalid
    /// A response fetched before the current value arrived late. Kept out so an
    /// out-of-order network response cannot roll config back.
    case rejectedOutOfOrder
}

/// Remote config with a last-known-good fallback and a compiled-in default.
///
/// Static stability for config means: the app's behaviour during an outage is the
/// behaviour it had just before the outage, not a behaviour it falls into because a
/// fetch failed. The type only ever moves forward to a newer, validated value.
public struct LastKnownGood<Value: Sendable & Equatable>: Sendable {
    public let bundled: Value
    public let policy: StalenessPolicy
    public private(set) var current: Value?
    public private(set) var fetchedAt: Instant?

    public init(bundled: Value, policy: StalenessPolicy = StalenessPolicy()) {
        self.bundled = bundled
        self.policy = policy
    }

    public mutating func offer(
        _ value: Value,
        fetchedAt: Instant,
        isValid: (Value) -> Bool
    ) -> OfferOutcome {
        guard isValid(value) else { return .rejectedInvalid }
        if let previous = self.fetchedAt, fetchedAt < previous { return .rejectedOutOfOrder }
        current = value
        self.fetchedAt = fetchedAt
        return .accepted
    }

    public func serve(at now: Instant) -> ServedConfig<Value> {
        guard let value = current, let stamp = fetchedAt else {
            return ServedConfig(value: bundled, provenance: .bundledDefault(.neverFetched))
        }
        // A clock set backwards makes the age negative; treat it as zero rather than
        // reporting a config from the future.
        let age = max(now.millis(since: stamp), 0)
        if age < policy.freshForMillis {
            return ServedConfig(value: value, provenance: .fresh(ageMillis: age))
        }
        if let limit = policy.maxStaleMillis, age > limit {
            return ServedConfig(value: bundled, provenance: .bundledDefault(.tooStale(ageMillis: age)))
        }
        return ServedConfig(value: value, provenance: .lastKnownGood(ageMillis: age))
    }
}
