import Foundation

/// One pending local write.
public struct OutboxEntry: Sendable, Codable, Equatable {
    /// The record this write targets. At most one entry per key is pending: later
    /// writes to the same key coalesce into it.
    public let recordKey: String
    public internal(set) var payload: Data
    /// The server version this write was based on. Updated when a push succeeds
    /// or a conflict is resolved in the local write's favour.
    public internal(set) var baseVersion: Int64
    /// When the oldest write folded into this entry was made. Coalescing keeps it,
    /// so "unsynced write age" never looks younger than it is.
    public let firstEnqueuedAt: Instant
    public internal(set) var lastModifiedAt: Instant
    /// Identifies this exact content. Changes on every coalesce. The transport sends
    /// it as the idempotency key, so a push whose response was lost can be retried
    /// without applying twice.
    public internal(set) var writeID: String
    public internal(set) var attempts: Int
}

/// A write the server refused permanently, kept for the app to surface.
public struct DeadLetter: Sendable, Codable, Equatable {
    public let entry: OutboxEntry
    public let reason: String
}

/// Synchronous persistence for the outbox.
///
/// Synchronous on purpose: ``DurableOutbox`` saves inside its actor without
/// suspending, so `.accepted` means "handed to the store" (for ``FileOutboxStore``,
/// written atomically by write-and-rename; there is no explicit fsync, so it
/// survives an app crash but is not guaranteed through a power loss), and two
/// interleaved enqueues can
/// never persist their snapshots out of order. The cost is that a slow disk blocks
/// the actor for one small write; for an outbox bounded at a few hundred entries
/// that is the right trade.
public protocol OutboxStore: Sendable {
    func load() throws -> [OutboxEntry]
    func save(_ entries: [OutboxEntry]) throws
}

/// In-memory store with injectable save and load failures, for tests and the demo.
public final class InMemoryOutboxStore: OutboxStore, @unchecked Sendable {
    // @unchecked: every access to the stored mutable properties goes through `lock`.
    private let lock = NSLock()
    private var saved: [OutboxEntry]
    private var failuresRemaining = 0
    private var loadFailuresRemaining = 0

    /// The injected failure thrown by `save` and `load`.
    public struct SaveFailed: Error {}

    public init(entries: [OutboxEntry] = []) {
        saved = entries
    }

    public func failNextSaves(_ count: Int) {
        lock.lock(); defer { lock.unlock() }
        failuresRemaining = max(count, 0)
    }

    public func failNextLoads(_ count: Int) {
        lock.lock(); defer { lock.unlock() }
        loadFailuresRemaining = max(count, 0)
    }

    public var snapshot: [OutboxEntry] {
        lock.lock(); defer { lock.unlock() }
        return saved
    }

    public func load() throws -> [OutboxEntry] {
        lock.lock(); defer { lock.unlock() }
        if loadFailuresRemaining > 0 {
            loadFailuresRemaining -= 1
            throw SaveFailed()
        }
        return saved
    }

    public func save(_ entries: [OutboxEntry]) throws {
        lock.lock(); defer { lock.unlock() }
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw SaveFailed()
        }
        saved = entries
    }
}

/// JSON file store with atomic replace. Payloads are stored as plain JSON; on iOS
/// the file gets `completeUntilFirstUserAuthentication` data protection. Encrypt
/// payloads yourself if they need more than that.
public struct FileOutboxStore: OutboxStore {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() throws -> [OutboxEntry] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([OutboxEntry].self, from: Data(contentsOf: url))
    }

    public func save(_ entries: [OutboxEntry]) throws {
        let data = try JSONEncoder().encode(entries)
        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
    }
}

/// The server's copy of a record, returned on conflict.
public struct RemoteRecord: Sendable, Equatable {
    public let recordKey: String
    public let version: Int64
    public let modifiedAt: Instant

    public init(recordKey: String, version: Int64, modifiedAt: Instant) {
        self.recordKey = recordKey
        self.version = version
        self.modifiedAt = modifiedAt
    }
}

public enum PushOutcome: Sendable, Equatable {
    case accepted(newVersion: Int64)
    case conflict(RemoteRecord)
    /// Retry later. The drain stops: the dependency is probably down, and hammering
    /// it with the rest of the queue only adds load.
    case transientFailure
    /// The server will never accept this write (validation, permissions).
    case permanentFailure(reason: String)
}

/// Sends one entry to the sync service (CloudKit, your own API).
public protocol SyncTransport: Sendable {
    func push(_ entry: OutboxEntry) async -> PushOutcome
}

public enum ConflictResolution: Sendable, Equatable {
    /// Rebase the local write onto the server version and push it again.
    case keepLocal
    /// Drop the local write; the server's copy wins.
    case keepRemote
}

public protocol ConflictResolver: Sendable {
    func resolve(local: OutboxEntry, remote: RemoteRecord) -> ConflictResolution
}

/// Last writer wins by modification time; the server wins ties, so two devices that
/// disagree converge on the same answer.
public struct LastWriterWins: ConflictResolver {
    public init() {}

    public func resolve(local: OutboxEntry, remote: RemoteRecord) -> ConflictResolution {
        local.lastModifiedAt > remote.modifiedAt ? .keepLocal : .keepRemote
    }
}

public enum EnqueueOutcome: Sendable, Equatable {
    case accepted
    /// Folded into the pending write for the same record.
    case coalesced
    /// Backpressure: the outbox holds `capacity` distinct records already. The
    /// caller decides what the user sees (for example, "saved on this device, sync
    /// paused"). Nothing is written, so nothing is silently lost.
    case rejectedFull
}

public struct DrainReport: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        /// Every pending record was offered once. Records parked after a conflict
        /// may still be pending (`remaining`); they go out on the next pass.
        case completed
        case stoppedOnTransientFailure
        case budgetExhausted
        /// Another drain was already running; this call did nothing.
        case alreadyDraining
        /// The persisted entries could not be loaded, so nothing was pushed: pushing
        /// without them could reorder or duplicate writes.
        case restoreFailed
    }

    public internal(set) var status: Status = .completed
    public internal(set) var pushed = 0
    /// A push succeeded, but a newer local write to the same record arrived while it
    /// was in flight. The newer write stays pending, rebased onto the new version.
    public internal(set) var supersededInFlight = 0
    public internal(set) var rebasedAfterConflict = 0
    public internal(set) var discardedForRemote = 0
    public internal(set) var deadLettered = 0
    public internal(set) var transientFailures = 0
    /// Saves that failed during the drain. In-memory state is still right; on a
    /// restart the affected writes are pushed again under the same `writeID`, which
    /// is why the transport must send it as an idempotency key.
    public internal(set) var persistenceFailures = 0
    public internal(set) var remaining = 0
}

/// A durable, bounded, coalescing outbox for writes made while sync is unavailable.
///
/// Invariants (each has a test, and the mutation script checks the tests bite):
/// - `enqueue` returns `.accepted`/`.coalesced` only after the store saved; if the
///   save throws, in-memory state is rolled back and the error rethrown.
/// - At most `capacity` distinct records are pending; beyond that, `.rejectedFull`.
/// - Only one drain runs at a time.
/// - A write that arrives while an older write to the same record is being pushed is
///   never lost: the actor suspends at `await transport.push`, so after resuming the
///   drain re-reads the entry and removes it only if its `writeID` is unchanged.
public actor DurableOutbox {
    // Immutable and Sendable, so readable from any isolation domain without `await`.
    public nonisolated let capacity: Int
    public nonisolated let deadLetterCapacity: Int
    private let store: any OutboxStore
    private let makeWriteID: @Sendable () -> String
    private var entries: [OutboxEntry] = []
    public private(set) var deadLetters: [DeadLetter] = []
    /// Dead letters dropped because `deadLetterCapacity` was reached.
    public private(set) var droppedDeadLetters = 0
    private var isDraining = false
    private var restored = false

    public init(
        capacity: Int,
        deadLetterCapacity: Int = 50,
        store: any OutboxStore,
        makeWriteID: @escaping @Sendable () -> String = { UUID().uuidString }
    ) {
        self.capacity = max(capacity, 0)
        self.deadLetterCapacity = max(deadLetterCapacity, 0)
        self.store = store
        self.makeWriteID = makeWriteID
    }

    /// Loads persisted entries. Safe to call more than once; only the first
    /// successful load does anything. `enqueue` and `drain` call it themselves, so a
    /// write made before an explicit restore can never save a snapshot that is
    /// missing the persisted entries (which would erase them from disk). Entries over
    /// `capacity` are kept (durable data is never dropped); new records are refused
    /// until the outbox drains below capacity.
    public func restore() throws {
        guard !restored else { return }
        entries = try store.load()
        restored = true
    }

    /// Discards every pending write, in memory and in the store, and marks the
    /// outbox restored. The escape hatch for a persisted queue that can no longer be
    /// decoded (`drain` reports `.restoreFailed` and `enqueue` throws until then).
    /// Destructive by design: call it only after deciding the queued writes are lost.
    public func resetDiscardingPendingWrites() throws {
        try store.save([])
        entries = []
        restored = true
    }

    public var pending: [OutboxEntry] { entries }

    public var count: Int { entries.count }

    /// Age of the oldest unsynced write, or `nil` when nothing is pending.
    public func oldestPendingAge(at now: Instant) -> Int64? {
        guard let oldest = entries.map(\.firstEnqueuedAt).min() else { return nil }
        return max(now.millis(since: oldest), 0)
    }

    public func enqueue(
        recordKey: String,
        payload: Data,
        baseVersion: Int64,
        at now: Instant
    ) throws -> EnqueueOutcome {
        try restore()
        let before = entries
        let outcome: EnqueueOutcome
        if let index = entries.firstIndex(where: { $0.recordKey == recordKey }) {
            entries[index].payload = payload
            entries[index].lastModifiedAt = now
            entries[index].writeID = makeWriteID()
            outcome = .coalesced
        } else {
            guard entries.count < capacity else { return .rejectedFull }
            entries.append(OutboxEntry(
                recordKey: recordKey,
                payload: payload,
                baseVersion: baseVersion,
                firstEnqueuedAt: now,
                lastModifiedAt: now,
                writeID: makeWriteID(),
                attempts: 0
            ))
            outcome = .accepted
        }
        do {
            try store.save(entries)
        } catch {
            entries = before
            throw error
        }
        return outcome
    }

    /// Pushes pending writes in order, at most `maxPushes` of them.
    ///
    /// Give `maxPushes` from a ``RecoveryGate`` so a fleet coming back from an
    /// outage does not stampede the sync service.
    public func drain(
        via transport: some SyncTransport,
        resolver: some ConflictResolver = LastWriterWins(),
        maxPushes: Int
    ) async -> DrainReport {
        var report = DrainReport()
        do {
            try restore()
        } catch {
            report.status = .restoreFailed
            report.persistenceFailures = 1
            return report
        }
        guard !isDraining else {
            report.status = .alreadyDraining
            report.remaining = entries.count
            return report
        }
        isDraining = true
        defer { isDraining = false }

        var budget = max(maxPushes, 0)
        // Records rebased this pass are not pushed again in the same pass, so a
        // server that always answers "conflict" cannot spin the drain.
        var parked = Set<String>()
        while let sent = entries.first(where: { !parked.contains($0.recordKey) }) {
            guard budget > 0 else {
                report.status = .budgetExhausted
                break
            }
            budget -= 1
            let outcome = await transport.push(sent)
            // Suspension point above: re-locate the entry, it may have changed.
            guard let index = entries.firstIndex(where: { $0.recordKey == sent.recordKey }) else { continue }
            let unchanged = entries[index].writeID == sent.writeID
            var stop = false
            switch outcome {
            case .accepted(let newVersion):
                if unchanged {
                    entries.remove(at: index)
                    report.pushed += 1
                } else {
                    entries[index].baseVersion = newVersion
                    report.supersededInFlight += 1
                }
            case .conflict(let remote):
                if unchanged, resolver.resolve(local: entries[index], remote: remote) == .keepRemote {
                    entries.remove(at: index)
                    report.discardedForRemote += 1
                } else {
                    // Either the resolver kept the local write, or a newer local write
                    // arrived mid-push and has not been judged yet: rebase and retry.
                    entries[index].baseVersion = remote.version
                    entries[index].attempts = Saturating.add(entries[index].attempts, 1)
                    parked.insert(sent.recordKey)
                    report.rebasedAfterConflict += 1
                }
            case .transientFailure:
                entries[index].attempts = Saturating.add(entries[index].attempts, 1)
                report.transientFailures += 1
                report.status = .stoppedOnTransientFailure
                stop = true
            case .permanentFailure(let reason):
                if unchanged {
                    let dead = entries.remove(at: index)
                    appendDeadLetter(DeadLetter(entry: dead, reason: reason))
                    report.deadLettered += 1
                } else {
                    // The refused content was replaced while in flight; the new
                    // content deserves its own attempt.
                    entries[index].attempts = Saturating.add(entries[index].attempts, 1)
                    parked.insert(sent.recordKey)
                }
            }
            do { try store.save(entries) } catch { report.persistenceFailures += 1 }
            if stop { break }
        }
        report.remaining = entries.count
        return report
    }

    private func appendDeadLetter(_ letter: DeadLetter) {
        guard deadLetterCapacity > 0 else {
            droppedDeadLetters = Saturating.add(droppedDeadLetters, 1)
            return
        }
        if deadLetters.count >= deadLetterCapacity {
            deadLetters.removeFirst()
            droppedDeadLetters = Saturating.add(droppedDeadLetters, 1)
        }
        deadLetters.append(letter)
    }
}
