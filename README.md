# StaticStability

**Your iOS app shouldn't go down because Apple did.**

On 17 November 2026, an Apple "internal update" took down Apple Account sign-in, Sign in with Apple, the App Store and iCloud together for hours ([MacRumors](https://www.macrumors.com/2026/11/17/apple-is-down-in-a-big-way-today/), [Apple's explanation](https://www.macrumors.com/2026/11/17/apple-outage-internal-update/)). In plenty of apps that meant users were signed out, subscribers lost features they had paid for, and edits made during the outage were gone.

This package is the client-side resilience layer that stops those things from happening. It makes an app **statically stable**: every decision the app makes about its users during an outage comes from state it already holds locally, so losing a dependency degrades a feature instead of breaking it. It ships with a deterministic fault-injection replay that runs the 17 November outage over 1,000 simulated clients and measures what users actually experienced.

| Replay of the 17 Nov outage, 1,000 clients, 6 hours | Naive | StaticStability |
|---|---:|---:|
| Foreground minutes with a usable session | 50.0% | **100%** |
| Paying users locked out (user-minutes) | 3,179 | **0** |
| Writes lost | 7,935 of 21,626 (36.7%) | **0** |
| Requests sent to services that were down | 233,449 | **35,901** (−84.6%) |
| Peak sync requests per minute | 1,042 | **336** (3.1× lower) |
| *Cost:* cancelled users still granted access (user-minutes) | 0 | 266 |
| *Cost:* oldest unsynced write (minutes) | 182 | 225 |

The last two rows are the price of the design, and the replay reports them on purpose. The [demo app](#demo-app) shows the table, the recovery-traffic chart and a minute-by-minute view of what one user sees.

## Why this matters

"Static stability" is the property AWS designs its data planes around: when a control plane fails, the parts already running keep working on what they last knew, and nothing has to call the failed service in order to keep going. Most iOS apps break this rule without anyone deciding to. Each dependency gets a sensible-looking policy on its own:

- Sign the user out if the credential-state check fails.
- Trust the receipt until it expires, then re-check with the store.
- Retry the sync queue whenever the app comes to the foreground.
- Call the cloud model for AI features.

Each of these is fine until the dependency it relies on goes down. Then the first signs everyone out, the second locks out every subscriber whose renewal fell inside the outage, the third hammers a dead service and then stampedes it at recovery, and the fourth breaks AI features outright. And when one company's outage takes out identity, payments and sync at the same moment, all four fail together.

Designing for this is an engineering-lead problem rather than a feature problem. The decisions are trade-offs (how long a grace window, how much free access you will give away, how long a write may wait), they touch every team's feature, and they need a shared mechanism plus numbers to argue with. This package supplies both.

## What's in it

```
 per-dependency health            local decisions                         what the user sees
┌────────────────────┐   ┌──────────────────────────────────────┐   ┌───────────────────────┐
│ CircuitBreaker      │──▶│ SessionContinuity   (identity)        │──▶│                       │
│  rate-based, probe- │   │ EntitlementPolicy   (StoreKit)        │   │  DegradationPlanner   │
│  driven, jittered   │   │ DurableOutbox +     (iCloud sync)     │   │  full / degraded /    │
│  cooldown, one      │   │   RecoveryGate                        │   │  unavailable, with    │
│  half-open probe    │   │ LastKnownGood       (remote config)   │   │  the reason in words  │
│                     │   │ CapabilityRouter    (cloud AI)        │   │                       │
└────────────────────┘   └──────────────────────────────────────┘   └───────────────────────┘
          ▲                                  ▲
          └──────── OutageReplay drives all of these with scripted faults and reports SLOs
```

| Type | Problem it solves |
|---|---|
| `CircuitBreaker`, `BreakerPolicy` | Stops sending requests to a dependency that is down. It trips on a failure *rate* over a window, with a minimum sample count, so one bad request is noise rather than an outage. The cooldown is exponential and jittered per client, and half-open lets exactly one probe through at a time. |
| `SessionContinuity` | Tells "the provider said no" (`.revoked`, `.notFound`: sign out) apart from "the provider did not answer" (carry on). After a 7-day unverified budget the session becomes `.restricted` (read-only, sensitive actions paused), never signed out. |
| `EntitlementPolicy`, `VerifiedEntitlement` | Grants access from locally verified transactions. Past expiry, it grants a bounded grace (48 h by default) only while the store is unreachable. A refund or revocation always wins. |
| `MonotonicTimeGuard` | Stops the user stretching the grace or the session budget by setting the device clock back. |
| `DurableOutbox` (actor) | A bounded, coalescing, persisted queue for writes made while sync is down. It applies backpressure (`.rejectedFull`) instead of dropping writes, runs one drain at a time, and is safe under actor reentrancy (see below). It loads the persisted queue before its first write or drain, so a write made at launch cannot overwrite it on disk. Conflicts go to a pluggable `ConflictResolver` (`LastWriterWins` included). |
| `RecoveryJitter`, `TokenBucket`, `RecoveryGate` | Herd control at recovery. Each install gets a deterministic slot in a 30-minute window from a stable hash of its installation ID and the recovery epoch, then sends through a token bucket that keeps fractional refill. |
| `LastKnownGood` | Remote config that serves the last validated value for as long as the config service is down, by default with no time limit. It refuses an invalid push and refuses an out-of-order response that would roll config back. |
| `CapabilityRouter`, `AITask`, `AIRoute` | Fails over from the cloud model to the on-device model and says exactly which capabilities were lost, so the UI can label a reduced answer. A task that needs a capability only the cloud has comes back `.unavailable`. It is never silently sent to a weaker model. |
| `DegradationPlanner` | Turns the decisions above into one status per feature, with user-facing text. |
| `OutageReplay`, `OutageScenario`, `ReplayReport` | The fault-injection harness: a minute-by-minute replay over a simulated fleet, comparing the naive policies above with this package. |

## Design decisions and trade-offs

**Every policy is a pure value type that takes `now` as a parameter.** There is no clock, timer or lock inside the breaker, the entitlement policy or the session logic. That is what makes the replay deterministic across 1,000 clients and 360 minutes, and what lets the tests cover clock rollback, `Int64.max` instants and hostile config without mocking a system clock. *Rejected:* an injected `Clock` protocol. It works, but every test has to manage shared mutable time, and the breaker can no longer be a cheap `Equatable` value that a simulation copies thousands of times.

**The breaker trips on a rate with a minimum sample count, not on N consecutive failures.** A consecutive-failure counter trips on one bad cell-tower handoff and never trips on a 50%-failing dependency that alternates. *Trade-off:* it needs `minimumSamples` requests to notice an outage, so the first few requests in an outage still go out. Those are counted in the replay's "requests sent to services that were down".

**The cooldown jitter is per client and deterministic.** Without it, every client that tripped in the same minute probes in the same minute, and the probes become their own herd. The jitter comes from FNV-1a and SplitMix64, not from Swift's `Hasher`, which is seeded per process and so would reshuffle every client on each relaunch.

**The entitlement grace is bounded and applies only while the store is unreachable.** *Rejected:* no grace, which locked paying users out for 3,179 user-minutes in the replay. *Also rejected:* unlimited grace, which turns any outage (or a user blocking the store's hosts) into free access forever. 48 hours covers the outages we have seen. The cost shows up as `falseGrantUserMinutes` (266 in the replay), which is the number a product owner should sign off on.

**Over budget, a session is restricted rather than signed out.** Signing someone out during an outage they can't sign back in through destroys their local state for nothing. Restricted mode keeps their data readable and pauses only the actions that really need a fresh identity.

**The outbox persists synchronously inside the actor.** `enqueue` returns `.accepted` only after the store has saved, and it never suspends between changing state and saving, so two interleaved enqueues cannot save their snapshots out of order. *Trade-off:* a slow disk blocks the actor for one small write. That is acceptable for a queue bounded at a few hundred entries. *Rejected:* an `async` store, which reintroduces the ordering problem and needs a generation counter to fix it.

**Actor reentrancy is handled by write identity, not by locking.** The drain suspends at `await transport.push`. While it is suspended, a newer edit to the same record can coalesce into the pending entry, and then the push of the *old* content succeeds. Removing the entry by record key at that point silently drops the user's latest edit. Every coalesce assigns a fresh `writeID`, and after resuming, the drain removes the entry only if the ID is unchanged. Otherwise it rebases the newer write onto the version just created. `testWriteDuringInFlightPushIsNotLost` reproduces the interleaving through a transport that re-enters the outbox mid-push.

**A transient failure stops the drain.** If the dependency just failed, pushing the rest of the queue only adds load. Records rebased after a conflict are parked until the next pass, so a server that always answers "conflict" cannot spin the drain.

**The recovery gate fixes the peak by policy rather than by backlog.** After recovery, each client waits for its slot and then sends at most `pushesPerMinute`. Fleet peak is then roughly active clients × rate, whatever the size of the backlog. *Trade-off:* the backlog drains more slowly, which is why the oldest unsynced write waited 225 minutes instead of 182. The naive figure looks better only because the naive client lost its oldest writes when its process was killed.

**AI degradation is explicit.** `AIRoute.reduced` carries the lost capabilities and a notice. A summary without web sources that is labelled as such beats one that is quietly worse.

## Verification

- `swift build -Xswiftc -warnings-as-errors` from a clean `.build`: 0 warnings, 0 errors (Swift 6.4.2, Xcode 27.2, Swift 6 language mode).
- `swift test`: **95 XCTest tests, 0 failures** on macOS. The suite covers trapping-arithmetic edges (`Int64.max` instants, `.max` grace, hostile breaker and replay config), empty and boundary states, breaker cooldown sequences, clock rollback, the outbox reentrancy interleaving, concurrent drains, save-failure rollback, dead-letter bounds, token-bucket remainder carry, jitter uniformity, and replay invariants (every write accounted for, identical workloads, golden values recorded from an earlier process).
- **Tests that would fail against a broken implementation.** `scripts/mutation-check.sh` re-introduces 30 specific bugs, one per claim in this README (single-error tripping, removing the reentrancy check, discarding the token-bucket remainder, a constant jitter, and so on), and requires each one to fail the suite. The uniformity check is itself tested against a constant spread and a half-window spread, both of which it must reject. Result: **30/30 caught**.
- CI ([Actions](https://github.com/rajatslakhina/static-stability-kit/actions)): a Linux job (`swift:6.0`, warnings as errors, full test suite), a macOS job (tests plus a generic iOS Simulator build of the library), and the mutation check.

## Honest limits

- **No Apple framework code.** The package does not import StoreKit, AuthenticationServices or CloudKit. `VerifiedEntitlement` must be built from a `VerificationResult.verified` transaction, which is where the JWS signature check happens. `CredentialCheckResult` maps from `getCredentialState`, and `SyncTransport` wraps your CloudKit or API calls. That keeps the policies testable on Linux, but the adapters are yours to write.
- **The replay is a model, not a measurement.** A dependency is either up or down in a given minute. There is no latency, partial failure or server capacity. The outage's three-hour length and simultaneous start are illustrative. Renewals are concentrated into a 24-hour band so a 3-hour outage visibly affects a 1,000-client run: with real monthly renewals, about 0.4% of subscribers renew during a 3-hour outage, which is still tens of thousands of people for a large app. The sync queue in the replay is a list of enqueue times per client. The real `DurableOutbox` (persistence, coalescing, reentrancy) is covered by its own tests, not by the replay.
- **The naive baseline is a composite.** It is one common policy per dependency, not a model of any particular app. It also understates naive harm in one way: it signs the user straight back in when identity returns, with no re-login friction.
- **The compound scenario shows one small regression.** With the cloud AI provider down for 90 minutes, the stable design answers 91.2% of AI requests against the naive 75.2%. But the cloud's breaker is still cooling down for a few minutes after the provider recovers, so 99 requests that the cloud could have answered went on-device or failed instead. That is the price of probing rather than hammering.
- **Dead letters are kept in memory only**, up to `deadLetterCapacity`. `FileOutboxStore` rewrites the whole JSON file on every change, which suits a bounded queue but not a large one.
- **`MonotonicTimeGuard` only defends against the clock moving backwards.** A fresh install has no high-water mark, and a clock moved forward and then back errs towards ending grace early.
- **Breakers live per process.** An app and its extensions each keep their own. Nothing here coordinates across processes or devices.
- **The on-device capability set (`InferenceBackend.onDevice`) is an assumption** and a product decision, not a measurement of any model.

## Install

```swift
.package(url: "https://github.com/rajatslakhina/static-stability-kit.git", from: "1.0.0")
```

```swift
import StaticStability

var identity = CircuitBreaker()
var session = SessionContinuity()
var clock = MonotonicTimeGuard()

let now = clock.observe(Instant(Date()))
let decision: SessionDecision
if identity.permitsRequest(at: now) {
    let state = await credentialState()          // your getCredentialState wrapper
    identity.record(success: state != .unavailable, at: now)
    decision = session.evaluate(state, at: now)
} else {
    decision = session.decisionWithoutProvider(at: now)
}
```

Persist `MonotonicTimeGuard`, `SessionContinuity.lastVerifiedAt` and the outbox store between launches. They are the local state the whole design depends on.

## Demo app

Demo app: (added after the companion repo is pushed — see below)

## License

MIT
