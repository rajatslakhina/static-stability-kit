/// Something an AI backend can do. Kept coarse on purpose: these are the
/// distinctions a product team has to make when the cloud model is down, not a
/// benchmark taxonomy.
public enum AICapability: String, Sendable, Codable, CaseIterable, Comparable {
    case shortRewrite
    case classification
    case extraction
    case longContextSummary
    case toolUse
    case webGrounding

    public static func < (lhs: AICapability, rhs: AICapability) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var displayName: String {
        switch self {
        case .shortRewrite: return "short rewrite"
        case .classification: return "classification"
        case .extraction: return "extraction"
        case .longContextSummary: return "long-context summary"
        case .toolUse: return "tool use"
        case .webGrounding: return "web grounding"
        }
    }
}

/// One place inference can run, in order of preference.
public struct InferenceBackend: Sendable, Equatable {
    public let name: String
    public let capabilities: Set<AICapability>

    public init(name: String, capabilities: Set<AICapability>) {
        self.name = name
        self.capabilities = capabilities
    }

    /// A cloud model such as Claude: everything.
    public static let cloud = InferenceBackend(name: "Claude (cloud)", capabilities: Set(AICapability.allCases))

    /// An on-device model such as Apple's Foundation Models: short-context work only.
    /// The exact set is a product decision; this is a conservative default.
    public static let onDevice = InferenceBackend(
        name: "On-device model",
        capabilities: [.shortRewrite, .classification, .extraction]
    )
}

/// A user-facing AI feature, described by what it must have and what makes it better.
public struct AITask: Sendable, Equatable {
    public let name: String
    /// Without these the task cannot run at all.
    public let required: Set<AICapability>
    /// The task runs without these, but visibly worse.
    public let preferred: Set<AICapability>

    public init(name: String, required: Set<AICapability>, preferred: Set<AICapability> = []) {
        self.name = name
        self.required = required
        self.preferred = preferred.subtracting(required)
    }
}

/// Where a task runs, and what the user must be told about it.
public enum AIRoute: Sendable, Equatable {
    case full(backend: String)
    /// Ran on a fallback that lacks some preferred capabilities. `notice` is shown in
    /// the UI: a quietly worse answer is worse than an honestly reduced one.
    case reduced(backend: String, lost: [AICapability], notice: String)
    case unavailable(missing: [AICapability], notice: String)

    public var isServed: Bool {
        if case .unavailable = self { return false }
        return true
    }
}

/// Routes AI tasks across backends in preference order, never silently.
///
/// The router picks the first *available* backend that has every required
/// capability. If that backend lacks preferred ones, the route says which, so the
/// UI can label the result ("Summary without web sources: cloud model unavailable").
public struct CapabilityRouter: Sendable, Equatable {
    public let backends: [InferenceBackend]

    public init(backends: [InferenceBackend] = [.cloud, .onDevice]) {
        self.backends = backends
    }

    public func route(_ task: AITask, isAvailable: (InferenceBackend) -> Bool) -> AIRoute {
        let live = backends.filter(isAvailable)
        guard let chosen = live.first(where: { task.required.isSubset(of: $0.capabilities) }) else {
            let reachable = live.reduce(into: Set<AICapability>()) { $0.formUnion($1.capabilities) }
            let missing = task.required.subtracting(reachable).sorted()
            guard !missing.isEmpty else {
                // Every required capability exists somewhere, but no single available
                // model has all of them (or no model is available for an empty set).
                let all = task.required.sorted().map(\.displayName).joined(separator: ", ")
                let notice = all.isEmpty
                    ? "\(task.name) has no model available right now."
                    : "\(task.name) needs \(all) together, and no single available model provides all of them."
                return .unavailable(missing: [], notice: notice)
            }
            let names = missing.map(\.displayName).joined(separator: ", ")
            return .unavailable(
                missing: missing,
                notice: "\(task.name) needs \(names), which no available model provides right now."
            )
        }
        let lost = task.preferred.subtracting(chosen.capabilities).sorted()
        guard !lost.isEmpty else { return .full(backend: chosen.name) }
        let names = lost.map(\.displayName).joined(separator: ", ")
        return .reduced(
            backend: chosen.name,
            lost: lost,
            notice: "\(task.name): answered by \(chosen.name), without \(names)."
        )
    }
}
