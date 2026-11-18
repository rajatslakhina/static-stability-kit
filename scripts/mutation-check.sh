#!/usr/bin/env bash
# Each mutant re-introduces a specific bug the README says the design prevents.
# A mutant "survives" if the test suite still passes with it applied: that means the
# claim is untested. The script fails if any mutant survives, if a mutant does not
# compile, if a pattern is not found exactly once, or if the unmutated suite fails.
# Runs on macOS and Linux (the library has no Apple-only code).
set -u
cd "$(dirname "$0")/.."
S=Sources/StaticStability
# file | exact text to replace (must occur exactly once) | replacement | the claim it breaks
MUTANTS=(
  "$S/CircuitBreaker.swift|guard count >= policy.minimumSamples, count > 0 else|guard count > 0 else|one failed request does not trip the breaker"
  "$S/CircuitBreaker.swift|guard !probeInFlight else { return false }|_ = probeInFlight|half-open admits exactly one probe at a time"
  "$S/CircuitBreaker.swift|times: consecutiveTrips - 1,|times: 0,|cooldown doubles on each consecutive trip"
  "$S/CircuitBreaker.swift|let jitter = Int64(draw)|let jitter = Int64(draw) * 0|clients that trip together do not reopen in lockstep"
  "$S/CircuitBreaker.swift|        if slots[oldest] { failures -= 1 }|        // (aging removed)|old outcomes age out of the window"
  "$S/CircuitBreaker.swift|so it is ignored.
            return false|so it is ignored.
            state = .closed
            return false|a late result while open is ignored"
  "$S/LastKnownGood.swift|if let previous = self.fetchedAt, fetchedAt < previous { return .rejectedOutOfOrder }|_ = self.fetchedAt|an out-of-order response cannot roll config back"
  "$S/LastKnownGood.swift|guard isValid(value) else { return .rejectedInvalid }|_ = isValid|an invalid push never replaces the last-known-good value"
  "$S/SessionContinuity.swift|        case .unavailable:
            return decisionWithoutProvider(at: now)|        case .unavailable:
            return .signedOut(.neverVerified)|an identity outage never signs anyone out"
  "$S/SessionContinuity.swift|        return age <= maxUnverifiedMillis|        return true|the unverified-session budget is enforced"
  "$S/EntitlementGrace.swift|guard !storeReachable else { return .denied(.expired) }|guard false else { return .denied(.expired) }|paying users keep access during a store outage"
  "$S/EntitlementGrace.swift|        guard now < graceEnd else { return .denied(.expired) }|        _ = graceEnd|the outage grace is bounded"
  "$S/EntitlementGrace.swift|if let revoked = entitlement.revokedAt, revoked <= now { return .denied(.revoked) }|_ = entitlement.revokedAt|a refund revokes access even during an outage"
  "$S/DurableOutbox.swift|                if unchanged {
                    entries.remove(at: index)
                    report.pushed += 1|                if true {
                    entries.remove(at: index)
                    report.pushed += 1|a write that lands mid-push is not lost (actor reentrancy)"
  "$S/DurableOutbox.swift|            entries[index].writeID = makeWriteID()|            // writeID kept|coalescing changes the write ID"
  "$S/DurableOutbox.swift|        guard !isDraining else {|        guard true else {|only one drain runs at a time"
  "$S/DurableOutbox.swift|        try restore()
        let before = entries|        let before = entries|a write made before restore cannot erase the persisted queue"
  "$S/DurableOutbox.swift|            entries = before|            _ = before|a failed save rolls the enqueue back"
  "$S/DurableOutbox.swift|guard entries.count < capacity else { return .rejectedFull }|_ = capacity|the outbox is bounded"
  "$S/DurableOutbox.swift|                stop = true|                stop = false|a transient failure stops the drain"
  "$S/DurableOutbox.swift|                    parked.insert(sent.recordKey)
                    report.rebasedAfterConflict += 1|                    report.rebasedAfterConflict += 1|an always-conflicting server cannot spin the drain"
  "$S/DurableOutbox.swift|            deadLetters.removeFirst()|            _ = deadLetters|dead letters are bounded"
  "$S/RecoveryGate.swift|        carry = units % 60_000|        carry = 0|slow refill rates are not lost to rounding"
  "$S/RecoveryGate.swift|        return Int64(hash % UInt64(windowMillis))|        return Int64(hash % 2)|the fleet is spread across the recovery window"
  "$S/RecoveryGate.swift|            guard now >= slot else { return false }|            _ = slot|a client waits for its jittered slot"
  "$S/RecoveryGate.swift|        guard now > lastRefill else { return }|        guard now != lastRefill else { return }|a clock moved backwards earns no tokens"
  '$S/CapabilityRouter.swift|let lost = task.preferred.subtracting(chosen.capabilities).sorted()|let lost: [AICapability] = []|a fallback route says what it lost'
  '$S/CapabilityRouter.swift|guard let chosen = live.first(where: { task.required.isSubset(of: $0.capabilities) }) else {|guard let chosen = live.first else {|a task is never routed to a model that lacks a required capability'
  "$S/Time.swift|        return mark|        return wallClock|setting the clock back cannot stretch time-based budgets"
  "$S/Time.swift|        return (a < 0) == (b < 0) ? .max : .min|        return result|arithmetic saturates instead of wrapping"
)
if command -v timeout >/dev/null; then LIMIT="timeout 300"; else LIMIT="perl -e alarm(300);exec(@ARGV)"; fi
if ! swift build --build-tests -q >/dev/null 2>&1 || ! $LIMIT swift test --skip-build >/dev/null 2>&1; then
  echo "BASELINE FAILED: the unmutated suite must pass before mutants mean anything"; exit 2
fi
echo "baseline: unmutated suite passes"
survived=0; caught=0
BACKUP=$(mktemp -d); CURRENT=""
trap '[ -n "$CURRENT" ] && cp "$BACKUP/orig" "$CURRENT"; rm -rf "$BACKUP"' EXIT
for entry in "${MUTANTS[@]}"; do
  entry=${entry//\$S/$S}
  IFS='|' read -r file from to claim <<< "$(printf '%s' "$entry" | tr '\n' '\001')"
  file=${file//$'\001'/$'\n'}; from=${from//$'\001'/$'\n'}; to=${to//$'\001'/$'\n'}; claim=${claim//$'\001'/$'\n'}
  cp "$file" "$BACKUP/orig"; CURRENT="$file"
  count=$(FROM="$from" perl -0777 -ne '$f=$ENV{FROM}; $c = () = /\Q$f\E/g; print $c' "$file")
  if [ "$count" != "1" ]; then echo "SETUP ERROR: pattern occurs $count times in $file: $claim"; CURRENT=""; exit 2; fi
  FROM="$from" TO="$to" perl -0777 -pi -e 'BEGIN { $f = $ENV{FROM}; $t = $ENV{TO} } s/\Q$f\E/$t/' "$file"
  if ! swift build --build-tests -q >/dev/null 2>&1; then
    echo "SETUP ERROR: mutant does not compile: $claim"; cp "$BACKUP/orig" "$file"; CURRENT=""; exit 2
  fi
  if $LIMIT swift test --skip-build >/dev/null 2>&1; then
    echo "SURVIVED: $claim"; survived=$((survived+1))
  else
    echo "caught:   $claim"; caught=$((caught+1))
  fi
  cp "$BACKUP/orig" "$file"; CURRENT=""
done
echo "mutants caught: $caught/$((caught+survived))"
[ "$survived" -eq 0 ]
