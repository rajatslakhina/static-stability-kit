/// Hashing that is identical on every launch, device and OS version.
///
/// Swift's `Hasher` is randomly seeded per process, so `hashValue` cannot be used to
/// spread clients across a recovery window: every relaunch would move every client,
/// and a test run in one process could never notice. FNV-1a is stable by definition.
public enum StableHash {
    private static let offsetBasis: UInt64 = 0xcbf2_9ce4_8422_2325
    private static let prime: UInt64 = 0x0000_0100_0000_01b3

    /// 64-bit FNV-1a over `bytes`.
    public static func fnv1a64<S: Sequence>(_ bytes: S) -> UInt64 where S.Element == UInt8 {
        var hash = offsetBasis
        for byte in bytes {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return hash
    }

    /// 64-bit FNV-1a over the UTF-8 bytes of `string`.
    public static func fnv1a64(_ string: String) -> UInt64 {
        fnv1a64(string.utf8)
    }

    /// Combines two values and runs the SplitMix64 finaliser over the result, so
    /// consecutive inputs (epoch 1, 2, 3) land far apart.
    public static func mix(_ a: UInt64, _ b: UInt64) -> UInt64 {
        var z = a ^ (b &* 0x9e37_79b9_7f4a_7c15)
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        return z ^ (z >> 31)
    }
}

/// A small, seedable, deterministic random number generator (SplitMix64).
public struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    public mutating func next() -> UInt64 {
        state = state &+ 0x9e37_79b9_7f4a_7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        return z ^ (z >> 31)
    }

    /// `true` with probability `percent`/100. Values outside 0...100 are clamped.
    public mutating func chance(percent: Int) -> Bool {
        let p = UInt64(min(max(percent, 0), 100))
        return next() % 100 < p
    }

    /// A value in `0..<bound`, or 0 when `bound` is not positive.
    public mutating func below(_ bound: Int) -> Int {
        guard bound > 0 else { return 0 }
        // `bound` is positive, so it fits in UInt64 and the remainder fits in Int.
        return Int(next() % UInt64(bound))
    }
}
