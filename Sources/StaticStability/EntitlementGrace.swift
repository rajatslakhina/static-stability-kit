/// An entitlement the app has already verified locally.
///
/// On iOS this is built from a StoreKit 2 `VerificationResult.verified` transaction
/// (`Transaction.currentEntitlements`), whose JWS signature StoreKit checks on
/// device. This package does not import StoreKit: it takes the verified facts as
/// input so the policy is testable on Linux and in the replay. Verifying the JWS is
/// the caller's job, and the type's name is a promise the caller has to keep.
public struct VerifiedEntitlement: Sendable, Codable, Equatable {
    public let productID: String
    /// `nil` for a non-expiring purchase.
    public let expiresAt: Instant?
    /// Set when the store reported a refund or revocation.
    public let revokedAt: Instant?
    public let verifiedAt: Instant

    public init(productID: String, expiresAt: Instant?, revokedAt: Instant? = nil, verifiedAt: Instant) {
        self.productID = productID
        self.expiresAt = expiresAt
        self.revokedAt = revokedAt
        self.verifiedAt = verifiedAt
    }
}

public enum EntitlementBasis: Sendable, Equatable {
    /// Inside the verified expiry.
    case verified
    /// Past the verified expiry while the store is unreachable. The renewal probably
    /// happened; the app just cannot see it yet.
    case outageGrace(remainingMillis: Int64)
}

public enum EntitlementDenial: Sendable, Equatable {
    case noVerifiedTransaction
    case revoked
    case expired
}

public enum EntitlementDecision: Sendable, Equatable {
    case granted(EntitlementBasis)
    case denied(EntitlementDenial)

    public var isGranted: Bool {
        if case .granted = self { return true }
        return false
    }
}

/// Decides access from locally verified transactions, with a bounded grace window
/// that applies only while the store is unreachable.
///
/// The trade-off is explicit: during an outage, a subscriber who really did cancel
/// keeps access for up to `outageGraceMillis` past expiry. The alternative is that
/// every subscriber whose renewal falls inside the outage is locked out of
/// something they paid for. The replay reports both numbers so the cost of the
/// grace is visible, not hidden.
public struct EntitlementPolicy: Sendable, Equatable {
    public let outageGraceMillis: Int64

    public init(outageGraceMillis: Int64 = Millis.hours(48)) {
        self.outageGraceMillis = max(outageGraceMillis, 0)
    }

    /// - Parameters:
    ///   - storeReachable: whether the app could refresh transactions just now. Pass
    ///     `false` when a circuit breaker for the store is not closed.
    ///   - now: an effective instant from ``MonotonicTimeGuard``, so setting the
    ///     clock back cannot extend the grace.
    public func decide(
        _ entitlement: VerifiedEntitlement?,
        storeReachable: Bool,
        at now: Instant
    ) -> EntitlementDecision {
        guard let entitlement else { return .denied(.noVerifiedTransaction) }
        if let revoked = entitlement.revokedAt, revoked <= now { return .denied(.revoked) }
        guard let expiry = entitlement.expiresAt else { return .granted(.verified) }
        if now < expiry { return .granted(.verified) }
        guard !storeReachable else { return .denied(.expired) }
        let graceEnd = expiry.advanced(byMillis: outageGraceMillis)
        guard now < graceEnd else { return .denied(.expired) }
        return .granted(.outageGrace(remainingMillis: graceEnd.millis(since: now)))
    }
}
