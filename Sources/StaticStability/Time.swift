import Foundation

/// Integer arithmetic that clamps at the type's bounds instead of trapping.
///
/// Every duration and counter in this package goes through these helpers, so no
/// value reachable through the public API (a huge grace window, a far-future
/// instant, a corrupted persisted counter) can crash the app with an overflow trap.
enum Saturating {
    static func add(_ a: Int64, _ b: Int64) -> Int64 {
        let (result, overflow) = a.addingReportingOverflow(b)
        guard overflow else { return result }
        return b > 0 ? .max : .min
    }

    static func subtract(_ a: Int64, _ b: Int64) -> Int64 {
        let (result, overflow) = a.subtractingReportingOverflow(b)
        guard overflow else { return result }
        return b < 0 ? .max : .min
    }

    static func multiply(_ a: Int64, _ b: Int64) -> Int64 {
        let (result, overflow) = a.multipliedReportingOverflow(by: b)
        guard overflow else { return result }
        return (a < 0) == (b < 0) ? .max : .min
    }

    static func add(_ a: Int, _ b: Int) -> Int {
        let (result, overflow) = a.addingReportingOverflow(b)
        guard overflow else { return result }
        return b > 0 ? .max : .min
    }

    /// `base * 2^exponent`, clamped to `0...cap`. A negative exponent is treated as 0.
    /// Constant time: a shift, guarded so it can never overflow.
    static func doubling(_ base: Int64, times exponent: Int, cap: Int64) -> Int64 {
        let ceiling = max(cap, 0)
        let value = min(max(base, 0), ceiling)
        let shift = max(exponent, 0)
        guard value > 0, shift > 0 else { return value }
        guard shift < 63 else { return ceiling }
        // value ≤ ceiling >> shift guarantees value << shift ≤ ceiling ≤ Int64.max.
        return value > ceiling >> shift ? ceiling : value << shift
    }
}

/// Milliseconds as `Int64`, with saturating constructors.
public enum Millis {
    public static func seconds(_ s: Int64) -> Int64 { Saturating.multiply(s, 1_000) }
    public static func minutes(_ m: Int64) -> Int64 { Saturating.multiply(m, 60_000) }
    public static func hours(_ h: Int64) -> Int64 { Saturating.multiply(h, 3_600_000) }
    public static func days(_ d: Int64) -> Int64 { Saturating.multiply(d, 86_400_000) }
}

/// A point in time, in milliseconds since an arbitrary epoch.
///
/// Every policy in this package takes the current instant as a parameter instead of
/// reading a clock. That keeps each decision a pure function of its inputs, which is
/// what lets the outage replay run deterministically and lets tests cover clock
/// rollback without mocking a system clock.
public struct Instant: Comparable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let millisSinceEpoch: Int64

    public init(millisSinceEpoch: Int64) {
        self.millisSinceEpoch = millisSinceEpoch
    }

    /// Milliseconds since 1970 for `date`. Non-finite or out-of-range values clamp
    /// instead of trapping in the `Double` to `Int64` conversion.
    public init(_ date: Date) {
        let millis = (date.timeIntervalSince1970 * 1_000).rounded(.down)
        if millis.isNaN {
            self.init(millisSinceEpoch: 0)
        } else if millis >= 9_223_372_036_854_775_807.0 {
            // Int64.max is not exactly representable as Double; anything at or above
            // the nearest Double (2^63) would trap on conversion.
            self.init(millisSinceEpoch: .max)
        } else if millis <= -9_223_372_036_854_775_808.0 {
            self.init(millisSinceEpoch: .min)
        } else {
            self.init(millisSinceEpoch: Int64(millis))
        }
    }

    /// `minute` whole minutes after the epoch (used by the replay and the tests).
    public static func minute(_ minute: Int) -> Instant {
        Instant(millisSinceEpoch: Millis.minutes(Int64(minute)))
    }

    public func advanced(byMillis delta: Int64) -> Instant {
        Instant(millisSinceEpoch: Saturating.add(millisSinceEpoch, delta))
    }

    /// Milliseconds from `earlier` to `self`; negative if `earlier` is later.
    public func millis(since earlier: Instant) -> Int64 {
        Saturating.subtract(millisSinceEpoch, earlier.millisSinceEpoch)
    }

    public static func < (lhs: Instant, rhs: Instant) -> Bool {
        lhs.millisSinceEpoch < rhs.millisSinceEpoch
    }

    public var description: String { "t+\(millisSinceEpoch)ms" }
}

/// Defends time-based policies against the device clock being moved backwards.
///
/// Grace windows and offline-session budgets are measured against wall-clock time,
/// which the user controls. Setting the clock back would otherwise stretch a 48-hour
/// outage grace indefinitely. The guard persists the latest instant it has seen and
/// never reports anything earlier.
///
/// What it does not catch, and what it costs:
/// - A clock moved *forward* and then back leaves the high-water mark in the
///   future until real time catches up. Until then every time-based policy sees the
///   future: a verified, unexpired subscription can be denied as expired, and a
///   session can turn `.restricted`. Call ``reanchor(to:)`` with a trusted
///   *current* time (the `Date` header of a fresh server response) to recover.
/// - A fresh install has no high-water mark, so it trusts the first time it sees.
public struct MonotonicTimeGuard: Sendable, Codable, Equatable {
    public private(set) var highWater: Instant?

    public init(highWater: Instant? = nil) {
        self.highWater = highWater
    }

    /// Replaces the high-water mark with a time the app trusts more than the device
    /// clock. This is the only way to move the mark backwards, and so the way to
    /// recover after the device clock was set forward and back.
    ///
    /// Pass a *current* trusted time, such as the `Date` header of a server response
    /// received just now. An older time (a cached transaction's signed date, say)
    /// moves the mark back by the difference, and the user can then set the clock
    /// back into that gap to stretch a grace or a session budget again.
    public mutating func reanchor(to trusted: Instant) {
        highWater = trusted
    }

    /// Records `wallClock` and returns the effective instant: the later of the two.
    public mutating func observe(_ wallClock: Instant) -> Instant {
        guard let mark = highWater, mark > wallClock else {
            highWater = wallClock
            return wallClock
        }
        return mark
    }
}
