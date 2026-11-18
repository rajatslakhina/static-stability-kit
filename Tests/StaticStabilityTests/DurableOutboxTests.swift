import Foundation
import XCTest
@testable import StaticStability

/// Deterministic write IDs: w1, w2, ...
private final class Counter: @unchecked Sendable {
    // @unchecked: `value` is only touched under `lock`.
    private let lock = NSLock()
    private var value = 0
    func next() -> String {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return "w\(value)"
    }
}

private func makeOutbox(capacity: Int = 10, deadLetters: Int = 50, store: InMemoryOutboxStore = InMemoryOutboxStore()) -> DurableOutbox {
    let counter = Counter()
    return DurableOutbox(capacity: capacity, deadLetterCapacity: deadLetters, store: store, makeWriteID: { counter.next() })
}

private func bytes(_ s: String) -> Data { Data(s.utf8) }

/// Replays a scripted outcome per push and records what it was sent.
private actor ScriptedTransport: SyncTransport {
    private var script: [PushOutcome]
    private(set) var sent: [OutboxEntry] = []

    init(_ script: [PushOutcome]) { self.script = script }

    func push(_ entry: OutboxEntry) async -> PushOutcome {
        sent.append(entry)
        guard !script.isEmpty else { return .accepted(newVersion: 1) }
        return script.removeFirst()
    }
}

/// While the first push is in flight, writes again to the same record through the
/// outbox: exactly the interleaving actor reentrancy allows.
private final class ReentrantTransport: SyncTransport, @unchecked Sendable {
    // @unchecked: `outbox` is set once before any push and never mutated after.
    var outbox: DurableOutbox?
    let outcome: PushOutcome
    init(outcome: PushOutcome) { self.outcome = outcome }

    func push(_ entry: OutboxEntry) async -> PushOutcome {
        if entry.writeID == "w1", let outbox {
            _ = try? await outbox.enqueue(recordKey: entry.recordKey, payload: Data("newer".utf8), baseVersion: 0, at: .minute(5))
        }
        return outcome
    }
}

/// Holds the first push until released, so a second drain can be started while it
/// is in flight. Later pushes return at once: if the single-drain guard were broken,
/// the second drain's push would complete and the test would fail fast, not hang.
private actor GatedTransport: SyncTransport {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var arrived: [CheckedContinuation<Void, Never>] = []
    private(set) var pushes = 0

    func push(_ entry: OutboxEntry) async -> PushOutcome {
        pushes += 1
        guard pushes == 1 else { return .accepted(newVersion: 1) }
        arrived.forEach { $0.resume() }
        arrived.removeAll()
        await withCheckedContinuation { waiting.append($0) }
        return .accepted(newVersion: 1)
    }

    func waitForFirstPush() async {
        guard pushes == 0 else { return }
        await withCheckedContinuation { arrived.append($0) }
    }

    func releaseAll() {
        waiting.forEach { $0.resume() }
        waiting.removeAll()
    }
}

final class DurableOutboxTests: XCTestCase {
    func testEnqueuePersistsBeforeReturning() async throws {
        let store = InMemoryOutboxStore()
        let outbox = makeOutbox(store: store)
        let outcome = try await outbox.enqueue(recordKey: "note-1", payload: bytes("a"), baseVersion: 0, at: .minute(1))
        XCTAssertEqual(outcome, .accepted)
        XCTAssertEqual(store.snapshot.map(\.recordKey), ["note-1"])
    }

    func testFailedSaveRollsBackAndRethrows() async throws {
        let store = InMemoryOutboxStore()
        let outbox = makeOutbox(store: store)
        _ = try await outbox.enqueue(recordKey: "a", payload: bytes("1"), baseVersion: 0, at: .minute(1))
        store.failNextSaves(1)
        do {
            _ = try await outbox.enqueue(recordKey: "a", payload: bytes("2"), baseVersion: 0, at: .minute(2))
            XCTFail("expected the save failure to propagate")
        } catch {}
        let pending = await outbox.pending
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.payload, bytes("1"), "the unsaved coalesce was rolled back")
        XCTAssertEqual(pending.first?.writeID, "w1")
        do {
            _ = try await outbox.enqueue(recordKey: "b", payload: bytes("x"), baseVersion: 0, at: .minute(3))
        } catch { XCTFail("store recovered, enqueue should succeed: \(error)") }
        let keys = await outbox.pending.map(\.recordKey)
        XCTAssertEqual(keys, ["a", "b"])
    }

    func testCoalescingKeepsOldestEnqueueTimeAndBaseButReplacesPayloadAndWriteID() async throws {
        let outbox = makeOutbox()
        _ = try await outbox.enqueue(recordKey: "a", payload: bytes("1"), baseVersion: 7, at: .minute(1))
        let outcome = try await outbox.enqueue(recordKey: "a", payload: bytes("2"), baseVersion: 99, at: .minute(9))
        XCTAssertEqual(outcome, .coalesced)
        let pending = await outbox.pending
        XCTAssertEqual(pending.count, 1)
        guard let entry = pending.first else { return }
        XCTAssertEqual(entry.payload, bytes("2"))
        XCTAssertEqual(entry.firstEnqueuedAt, .minute(1))
        XCTAssertEqual(entry.lastModifiedAt, .minute(9))
        XCTAssertEqual(entry.baseVersion, 7)
        XCTAssertEqual(entry.writeID, "w2")
        let age = await outbox.oldestPendingAge(at: .minute(10))
        XCTAssertEqual(age, Millis.minutes(9))
    }

    func testCapacityRejectsNewRecordsButStillCoalesces() async throws {
        let outbox = makeOutbox(capacity: 2)
        _ = try await outbox.enqueue(recordKey: "a", payload: bytes("1"), baseVersion: 0, at: .minute(1))
        _ = try await outbox.enqueue(recordKey: "b", payload: bytes("1"), baseVersion: 0, at: .minute(1))
        let third = try await outbox.enqueue(recordKey: "c", payload: bytes("1"), baseVersion: 0, at: .minute(1))
        XCTAssertEqual(third, .rejectedFull)
        let update = try await outbox.enqueue(recordKey: "a", payload: bytes("2"), baseVersion: 0, at: .minute(2))
        XCTAssertEqual(update, .coalesced, "edits to queued records are not backpressured")
        let count = await outbox.count
        XCTAssertEqual(count, 2)
    }

    func testZeroCapacityRejectsEverything() async throws {
        let outbox = makeOutbox(capacity: -4)
        let outcome = try await outbox.enqueue(recordKey: "a", payload: bytes("1"), baseVersion: 0, at: .minute(1))
        XCTAssertEqual(outcome, .rejectedFull)
    }

    func testDrainPushesInOrderAndEmpties() async throws {
        let outbox = makeOutbox()
        for key in ["a", "b", "c"] {
            _ = try await outbox.enqueue(recordKey: key, payload: bytes(key), baseVersion: 0, at: .minute(1))
        }
        let transport = ScriptedTransport([])
        let report = await outbox.drain(via: transport, maxPushes: 10)
        XCTAssertEqual(report.status, .completed)
        XCTAssertEqual(report.pushed, 3)
        XCTAssertEqual(report.remaining, 0)
        let sentKeys = await transport.sent.map(\.recordKey)
        XCTAssertEqual(sentKeys, ["a", "b", "c"])
        let age = await outbox.oldestPendingAge(at: .minute(5))
        XCTAssertNil(age)
    }

    func testDrainRespectsPushBudget() async throws {
        let outbox = makeOutbox()
        for key in ["a", "b", "c"] {
            _ = try await outbox.enqueue(recordKey: key, payload: bytes(key), baseVersion: 0, at: .minute(1))
        }
        let report = await outbox.drain(via: ScriptedTransport([]), maxPushes: 2)
        XCTAssertEqual(report.status, .budgetExhausted)
        XCTAssertEqual(report.pushed, 2)
        XCTAssertEqual(report.remaining, 1)
        let none = await outbox.drain(via: ScriptedTransport([]), maxPushes: -3)
        XCTAssertEqual(none.pushed, 0)
        XCTAssertEqual(none.remaining, 1)
    }

    func testTransientFailureStopsTheDrainAndKeepsTheWrite() async throws {
        let outbox = makeOutbox()
        for key in ["a", "b"] {
            _ = try await outbox.enqueue(recordKey: key, payload: bytes(key), baseVersion: 0, at: .minute(1))
        }
        let transport = ScriptedTransport([.transientFailure])
        let report = await outbox.drain(via: transport, maxPushes: 10)
        XCTAssertEqual(report.status, .stoppedOnTransientFailure)
        XCTAssertEqual(report.transientFailures, 1)
        XCTAssertEqual(report.remaining, 2)
        let sentCount = await transport.sent.count
        XCTAssertEqual(sentCount, 1, "no hammering a dependency that just failed")
        let attempts = await outbox.pending.first?.attempts
        XCTAssertEqual(attempts, 1)
    }

    func testWriteDuringInFlightPushIsNotLost() async throws {
        // The reentrancy hazard: the actor suspends at `await transport.push`, a newer
        // write to the same record coalesces in, and the push of the OLD content
        // succeeds. Removing the entry by key would silently drop the newer write.
        let outbox = makeOutbox()
        _ = try await outbox.enqueue(recordKey: "note", payload: bytes("old"), baseVersion: 3, at: .minute(1))
        let transport = ReentrantTransport(outcome: .accepted(newVersion: 4))
        transport.outbox = outbox
        let report = await outbox.drain(via: transport, maxPushes: 1)
        XCTAssertEqual(report.supersededInFlight, 1)
        XCTAssertEqual(report.pushed, 0)
        let pending = await outbox.pending
        XCTAssertEqual(pending.count, 1)
        guard let entry = pending.first else { return }
        XCTAssertEqual(entry.payload, bytes("newer"))
        XCTAssertEqual(entry.baseVersion, 4, "rebased onto the version the old push created")
        XCTAssertEqual(entry.writeID, "w2")
    }

    func testPermanentFailureOfSupersededContentKeepsTheNewerWrite() async throws {
        let outbox = makeOutbox()
        _ = try await outbox.enqueue(recordKey: "note", payload: bytes("old"), baseVersion: 0, at: .minute(1))
        let transport = ReentrantTransport(outcome: .permanentFailure(reason: "bad"))
        transport.outbox = outbox
        let report = await outbox.drain(via: transport, maxPushes: 5)
        XCTAssertEqual(report.deadLettered, 0)
        let pending = await outbox.pending
        XCTAssertEqual(pending.first?.payload, bytes("newer"))
    }

    func testOnlyOneDrainRunsAtATime() async throws {
        let outbox = makeOutbox()
        _ = try await outbox.enqueue(recordKey: "a", payload: bytes("1"), baseVersion: 0, at: .minute(1))
        let transport = GatedTransport()
        let first = Task { await outbox.drain(via: transport, maxPushes: 5) }
        await transport.waitForFirstPush()
        let second = await outbox.drain(via: transport, maxPushes: 5)
        XCTAssertEqual(second.status, .alreadyDraining)
        XCTAssertEqual(second.pushed, 0)
        await transport.releaseAll()
        let firstReport = await first.value
        XCTAssertEqual(firstReport.pushed, 1)
        let pushes = await transport.pushes
        XCTAssertEqual(pushes, 1, "the record was pushed once, not twice")
    }

    func testConflictResolvedForRemoteDiscardsLocal() async throws {
        let outbox = makeOutbox()
        _ = try await outbox.enqueue(recordKey: "a", payload: bytes("1"), baseVersion: 1, at: .minute(5))
        let remote = RemoteRecord(recordKey: "a", version: 2, modifiedAt: .minute(9))
        let report = await outbox.drain(via: ScriptedTransport([.conflict(remote)]), maxPushes: 5)
        XCTAssertEqual(report.discardedForRemote, 1)
        XCTAssertEqual(report.remaining, 0)
    }

    func testConflictResolvedForLocalRebasesAndParksForThisPass() async throws {
        let outbox = makeOutbox()
        _ = try await outbox.enqueue(recordKey: "a", payload: bytes("1"), baseVersion: 1, at: .minute(9))
        let remote = RemoteRecord(recordKey: "a", version: 6, modifiedAt: .minute(5))
        // A server that answers "conflict" forever must not spin the drain.
        let transport = ScriptedTransport(Array(repeating: .conflict(remote), count: 50))
        let report = await outbox.drain(via: transport, maxPushes: 50)
        XCTAssertEqual(report.rebasedAfterConflict, 1)
        let sentCount = await transport.sent.count
        XCTAssertEqual(sentCount, 1)
        let base = await outbox.pending.first?.baseVersion
        XCTAssertEqual(base, 6)
        // Next pass pushes the rebased write and succeeds.
        let next = await outbox.drain(via: ScriptedTransport([.accepted(newVersion: 7)]), maxPushes: 5)
        XCTAssertEqual(next.pushed, 1)
    }

    func testLastWriterWinsTieGoesToServer() {
        let entry = OutboxEntry(recordKey: "a", payload: Data(), baseVersion: 0, firstEnqueuedAt: .minute(1),
                                lastModifiedAt: .minute(5), writeID: "w", attempts: 0)
        XCTAssertEqual(LastWriterWins().resolve(local: entry, remote: RemoteRecord(recordKey: "a", version: 1, modifiedAt: .minute(5))), .keepRemote)
        XCTAssertEqual(LastWriterWins().resolve(local: entry, remote: RemoteRecord(recordKey: "a", version: 1, modifiedAt: .minute(4))), .keepLocal)
    }

    func testPermanentFailuresGoToBoundedDeadLetters() async throws {
        let outbox = makeOutbox(deadLetters: 2)
        for key in ["a", "b", "c"] {
            _ = try await outbox.enqueue(recordKey: key, payload: bytes(key), baseVersion: 0, at: .minute(1))
        }
        let failures = Array(repeating: PushOutcome.permanentFailure(reason: "forbidden"), count: 3)
        let report = await outbox.drain(via: ScriptedTransport(failures), maxPushes: 10)
        XCTAssertEqual(report.deadLettered, 3)
        let letters = await outbox.deadLetters.map(\.entry.recordKey)
        XCTAssertEqual(letters, ["b", "c"], "oldest dropped, newest kept")
        let dropped = await outbox.droppedDeadLetters
        XCTAssertEqual(dropped, 1)
    }

    func testRestoreReloadsPersistedEntriesOnceAndKeepsOverCapacityData() async throws {
        let store = InMemoryOutboxStore()
        let first = makeOutbox(capacity: 5, store: store)
        for key in ["a", "b", "c"] {
            _ = try await first.enqueue(recordKey: key, payload: bytes(key), baseVersion: 0, at: .minute(1))
        }
        // Relaunch with a smaller capacity.
        let second = makeOutbox(capacity: 2, store: store)
        try await second.restore()
        try await second.restore()
        let keys = await second.pending.map(\.recordKey)
        XCTAssertEqual(keys, ["a", "b", "c"], "durable writes are never dropped on restore")
        let outcome = try await second.enqueue(recordKey: "d", payload: bytes("d"), baseVersion: 0, at: .minute(2))
        XCTAssertEqual(outcome, .rejectedFull)
    }

    func testEnqueueBeforeExplicitRestoreDoesNotEraseThePersistedQueue() async throws {
        let store = InMemoryOutboxStore()
        let first = makeOutbox(store: store)
        _ = try await first.enqueue(recordKey: "a", payload: bytes("a"), baseVersion: 0, at: .minute(1))
        // Relaunch, and write before anyone calls restore().
        let second = makeOutbox(store: store)
        _ = try await second.enqueue(recordKey: "b", payload: bytes("b"), baseVersion: 0, at: .minute(2))
        XCTAssertEqual(store.snapshot.map(\.recordKey), ["a", "b"], "the persisted entry survived and kept its order")
    }

    func testDrainRefusesToRunWhenThePersistedQueueCannotBeLoaded() async throws {
        let store = InMemoryOutboxStore(entries: [])
        store.failNextLoads(1)
        let outbox = makeOutbox(store: store)
        let transport = ScriptedTransport([])
        let report = await outbox.drain(via: transport, maxPushes: 5)
        XCTAssertEqual(report.status, .restoreFailed)
        let sent = await transport.sent.count
        XCTAssertEqual(sent, 0)
        do {
            _ = try await outbox.enqueue(recordKey: "a", payload: bytes("a"), baseVersion: 0, at: .minute(1))
        } catch { XCTFail("the load succeeds on retry: \(error)") }
    }

    func testFileStoreRoundTripsAcrossInstances() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("outbox-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = FileOutboxStore(url: url)
        XCTAssertEqual(try store.load(), [], "missing file is an empty outbox")
        let outbox = DurableOutbox(capacity: 5, store: store)
        _ = try await outbox.enqueue(recordKey: "a", payload: bytes("hello"), baseVersion: 2, at: .minute(3))
        let relaunched = DurableOutbox(capacity: 5, store: FileOutboxStore(url: url))
        try await relaunched.restore()
        let entry = await relaunched.pending.first
        XCTAssertEqual(entry?.payload, bytes("hello"))
        XCTAssertEqual(entry?.baseVersion, 2)
        XCTAssertEqual(entry?.firstEnqueuedAt, .minute(3))
    }

    func testDrainSaveFailureIsReportedAndStateStaysCorrect() async throws {
        let store = InMemoryOutboxStore()
        let outbox = makeOutbox(store: store)
        _ = try await outbox.enqueue(recordKey: "a", payload: bytes("1"), baseVersion: 0, at: .minute(1))
        store.failNextSaves(1)
        let report = await outbox.drain(via: ScriptedTransport([]), maxPushes: 5)
        XCTAssertEqual(report.pushed, 1)
        XCTAssertEqual(report.persistenceFailures, 1)
        XCTAssertEqual(report.remaining, 0)
        XCTAssertEqual(store.snapshot.count, 1, "disk still holds it; a relaunch re-pushes under the same writeID")
        XCTAssertEqual(store.snapshot.first?.writeID, "w1")
    }
}
