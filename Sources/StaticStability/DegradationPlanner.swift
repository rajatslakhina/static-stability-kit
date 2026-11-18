/// The platform and vendor services an app depends on, as this package models them.
public enum Dependency: String, Sendable, Codable, CaseIterable {
    case identity
    case storeKit
    case cloudSync
    case remoteConfig
    case cloudAI

    public var displayName: String {
        switch self {
        case .identity: return "Sign in with Apple"
        case .storeKit: return "App Store / StoreKit"
        case .cloudSync: return "iCloud sync"
        case .remoteConfig: return "Remote config"
        case .cloudAI: return "Cloud AI (Claude)"
        }
    }
}

/// How one feature is working right now, in words a user can be shown.
public enum FeatureMode: Sendable, Equatable {
    case full
    case degraded(String)
    case unavailable(String)
}

public struct FeatureStatus: Sendable, Equatable, Identifiable {
    public let feature: String
    public let dependency: Dependency
    public let mode: FeatureMode

    public var id: String { feature }
}

/// Everything the planner needs, all of it held locally. Nothing in here requires a
/// network call to produce: that is what "statically stable" means.
public struct PostureInputs: Sendable {
    public var session: SessionDecision
    public var entitlement: EntitlementDecision
    public var pendingWrites: Int
    public var outboxCapacity: Int
    public var oldestPendingAgeMillis: Int64?
    public var syncAvailable: Bool
    public var configProvenance: ConfigProvenance
    public var aiRoute: AIRoute

    public init(
        session: SessionDecision,
        entitlement: EntitlementDecision,
        pendingWrites: Int,
        outboxCapacity: Int,
        oldestPendingAgeMillis: Int64?,
        syncAvailable: Bool,
        configProvenance: ConfigProvenance,
        aiRoute: AIRoute
    ) {
        self.session = session
        self.entitlement = entitlement
        self.pendingWrites = pendingWrites
        self.outboxCapacity = outboxCapacity
        self.oldestPendingAgeMillis = oldestPendingAgeMillis
        self.syncAvailable = syncAvailable
        self.configProvenance = configProvenance
        self.aiRoute = aiRoute
    }
}

/// Maps each dependency's local decision to a user-visible feature status.
public enum DegradationPlanner {
    public static func posture(_ inputs: PostureInputs) -> [FeatureStatus] {
        [
            FeatureStatus(feature: "Account", dependency: .identity, mode: sessionMode(inputs.session)),
            FeatureStatus(feature: "Premium features", dependency: .storeKit, mode: entitlementMode(inputs.entitlement)),
            FeatureStatus(feature: "Saving & sync", dependency: .cloudSync, mode: syncMode(inputs)),
            FeatureStatus(feature: "Feature flags", dependency: .remoteConfig, mode: configMode(inputs.configProvenance)),
            FeatureStatus(feature: "AI assistant", dependency: .cloudAI, mode: aiMode(inputs.aiRoute)),
        ]
    }

    static func sessionMode(_ decision: SessionDecision) -> FeatureMode {
        switch decision {
        case .active: return .full
        case .activeUnverified(let age):
            return .degraded("Signed in on this device; Apple sign-in unreachable for \(minutes(age)).")
        case .restricted(let age):
            return .degraded("Read-only: account not verified for \(minutes(age)). Purchases and account changes paused.")
        case .signedOut(let reason):
            switch reason {
            case .credentialRevoked: return .unavailable("Signed out: Apple ID access was revoked.")
            case .credentialNotFound: return .unavailable("Signed out: Apple ID credential not found.")
            case .neverVerified: return .unavailable("Not signed in.")
            }
        }
    }

    static func entitlementMode(_ decision: EntitlementDecision) -> FeatureMode {
        switch decision {
        case .granted(.verified): return .full
        case .granted(.outageGrace(let remaining)):
            return .degraded("Unlocked from your last receipt; App Store unreachable. Grace ends in \(minutes(remaining)).")
        case .denied(.noVerifiedTransaction): return .unavailable("No subscription on this device.")
        case .denied(.revoked): return .unavailable("Subscription refunded or revoked.")
        case .denied(.expired): return .unavailable("Subscription expired.")
        }
    }

    static func syncMode(_ inputs: PostureInputs) -> FeatureMode {
        if inputs.pendingWrites >= inputs.outboxCapacity, inputs.outboxCapacity > 0 {
            return .degraded("Sync queue full: new items stay on this device until iCloud returns.")
        }
        guard inputs.pendingWrites > 0 else {
            return inputs.syncAvailable ? .full : .degraded("iCloud unreachable. New changes will be saved here first.")
        }
        let age = inputs.oldestPendingAgeMillis.map(minutes) ?? "a moment"
        let tail = inputs.syncAvailable ? "syncing now" : "will sync when iCloud returns"
        return .degraded("\(inputs.pendingWrites) change(s) saved on this device, oldest \(age) old; \(tail).")
    }

    static func configMode(_ provenance: ConfigProvenance) -> FeatureMode {
        switch provenance {
        case .fresh: return .full
        case .lastKnownGood(let age): return .degraded("Using flags from \(minutes(age)) ago.")
        case .bundledDefault(.neverFetched): return .degraded("Using built-in defaults (never fetched).")
        case .bundledDefault(.tooStale(let age)): return .degraded("Using built-in defaults; last fetch \(minutes(age)) ago.")
        }
    }

    static func aiMode(_ route: AIRoute) -> FeatureMode {
        switch route {
        case .full: return .full
        case .reduced(_, _, let notice): return .degraded(notice)
        case .unavailable(_, let notice): return .unavailable(notice)
        }
    }

    /// "42 min", "3 h 5 min", "2 d 4 h".
    static func minutes(_ millis: Int64) -> String {
        let totalMinutes = max(millis, 0) / 60_000
        if totalMinutes < 60 { return "\(totalMinutes) min" }
        let hours = totalMinutes / 60
        if hours < 48 { return "\(hours) h \(totalMinutes % 60) min" }
        return "\(hours / 24) d \(hours % 24) h"
    }
}
