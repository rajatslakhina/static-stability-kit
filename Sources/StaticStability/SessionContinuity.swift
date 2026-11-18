/// The result of asking the identity provider about a credential (for Sign in with
/// Apple, `ASAuthorizationAppleIDProvider.getCredentialState`).
public enum CredentialCheckResult: Sendable, Equatable {
    case authorized
    case revoked
    case notFound
    /// The check itself failed: timeout, 5xx, network error. This says nothing
    /// about the user, only about the provider.
    case unavailable
}

/// What the app should do with the signed-in session right now.
public enum SessionDecision: Sendable, Equatable {
    /// Verified by the provider `verifiedAgoMillis` ago.
    case active(verifiedAgoMillis: Int64)
    /// The provider is unreachable. The session continues on the app's own token.
    case activeUnverified(unverifiedForMillis: Int64)
    /// Unverified for longer than the policy allows. The user keeps their data and
    /// read access but sensitive actions (purchases, account changes, exporting
    /// data) are blocked until verification succeeds. They are never signed out
    /// because a provider was down.
    case restricted(unverifiedForMillis: Int64)
    case signedOut(SignOutReason)

    /// Whether the user can see and work with their data.
    public var hasSession: Bool {
        switch self {
        case .active, .activeUnverified, .restricted: return true
        case .signedOut: return false
        }
    }
}

public enum SignOutReason: Sendable, Equatable {
    /// The provider positively said the credential is no longer valid.
    case credentialRevoked
    case credentialNotFound
    /// There is no session to continue.
    case neverVerified
}

/// Session continuity that does not depend on the identity provider being up.
///
/// The common failure: an app checks credential state on launch and signs the user
/// out on *any* non-authorized answer, so an identity outage signs out everyone who
/// opens the app, and they cannot sign back in until the outage ends. This type
/// separates "the provider said no" (sign out) from "the provider did not answer"
/// (carry on, within a bounded budget).
///
/// Pass an effective instant from ``MonotonicTimeGuard`` so the budget cannot be
/// stretched by setting the device clock back.
public struct SessionContinuity: Sendable, Equatable {
    public let maxUnverifiedMillis: Int64
    public private(set) var lastVerifiedAt: Instant?

    public init(maxUnverifiedMillis: Int64 = Millis.days(7), lastVerifiedAt: Instant? = nil) {
        self.maxUnverifiedMillis = max(maxUnverifiedMillis, 0)
        self.lastVerifiedAt = lastVerifiedAt
    }

    public mutating func evaluate(_ check: CredentialCheckResult, at now: Instant) -> SessionDecision {
        switch check {
        case .authorized:
            lastVerifiedAt = now
            return .active(verifiedAgoMillis: 0)
        case .revoked:
            lastVerifiedAt = nil
            return .signedOut(.credentialRevoked)
        case .notFound:
            lastVerifiedAt = nil
            return .signedOut(.credentialNotFound)
        case .unavailable:
            return decisionWithoutProvider(at: now)
        }
    }

    /// The decision when no check was made at all (for example, a circuit breaker
    /// refused the request locally). Same rules as `.unavailable`.
    public func decisionWithoutProvider(at now: Instant) -> SessionDecision {
        guard let verified = lastVerifiedAt else { return .signedOut(.neverVerified) }
        let age = max(now.millis(since: verified), 0)
        return age <= maxUnverifiedMillis
            ? .activeUnverified(unverifiedForMillis: age)
            : .restricted(unverifiedForMillis: age)
    }
}
