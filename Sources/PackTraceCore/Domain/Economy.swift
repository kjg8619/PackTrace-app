import Foundation

/// Points are a local development currency. They are not a claim about the
/// cost or value of any AI product.
public struct PackEconomy: Hashable, Sendable, Codable {
    public var version: Int
    public var initialDemoGrantPoints: Int
    public var packCostPoints: Int

    public init(version: Int, initialDemoGrantPoints: Int, packCostPoints: Int) {
        self.version = version
        self.initialDemoGrantPoints = initialDemoGrantPoints
        self.packCostPoints = packCostPoints
    }

    public static let v1 = PackEconomy(version: 1, initialDemoGrantPoints: 500, packCostPoints: 100)
}

public enum WalletReason: String, Sendable, Codable {
    case demoInitialGrant = "demo.initial_grant"
    case packExchange = "pack.exchange"
    case usageReward = "usage.reward"
    /// One-off adjustment that corrects credited usage which should never have
    /// been credited. The original reward entries stay in the ledger.
    case usageCorrection = "usage.correction"
    /// One-time reward for an unlocked achievement.
    case achievementReward = "achievement.reward"

    public var displayName: String {
        switch self {
        case .demoInitialGrant: "개발용 최초 지급"
        case .packExchange: "팩 교환"
        case .usageReward: "AI 사용량 적립"
        case .usageCorrection: "사용량 적립 보정"
        case .achievementReward: "업적 보상"
        }
    }

    /// Reasons that may only ever be written to the demo wallet.
    public var isDemoOnly: Bool {
        self == .demoInitialGrant
    }
}
