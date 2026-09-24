import Foundation

/// Deterministic generator so opening results can be reproduced from a stored
/// seed in tests and diagnostics. Not used for anything cryptographic.
public struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        self.state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Unbiased value in `0..<upperBound`.
    public mutating func next(upperBound: UInt64) -> UInt64 {
        precondition(upperBound > 0, "upperBound must be positive")
        let limit = UInt64.max - (UInt64.max % upperBound)
        var value = next()
        while value >= limit {
            value = next()
        }
        return value % upperBound
    }
}

public enum SeedSource {
    /// Seeds come from the system generator; only the *seed* is stored, so the
    /// draw itself never re-runs when the UI re-renders or the app restarts.
    public static func randomSeed() -> UInt64 {
        var generator = SystemRandomNumberGenerator()
        return generator.next()
    }
}
