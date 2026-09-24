import Foundation

/// Phantom-typed identifier. Keeps pack, opening, wallet and owned-card
/// identifiers from being mixed up while sharing one small implementation.
public struct ID<Phantom>: Hashable, Sendable, Codable, RawRepresentable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init() {
        self.rawValue = UUID().uuidString.lowercased()
    }

    public var description: String { rawValue }

    /// `source:language:setID:localID` — used when a stored card is no longer in
    /// any catalogue snapshot and only its key remains.
    public var setID: String {
        let parts = rawValue.split(separator: ":", omittingEmptySubsequences: false)
        return parts.count >= 3 ? String(parts[2]) : ""
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.rawValue = try container.decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum PackInstanceTag {}
public enum OpeningTag {}
public enum WalletEntryTag {}
public enum OwnedCardTag {}
public enum ExchangeRequestTag {}

public typealias PackInstanceID = ID<PackInstanceTag>
public typealias OpeningID = ID<OpeningTag>
public typealias WalletEntryID = ID<WalletEntryTag>
public typealias OwnedCardID = ID<OwnedCardTag>
public typealias ExchangeRequestID = ID<ExchangeRequestTag>

/// Demo and production books are separate databases on disk. Development
/// grants only ever land in `demo`, so they can never be mistaken for points
/// earned from real AI usage.
public enum Realm: String, Sendable, CaseIterable, Codable {
    case demo
    case production

    public var displayName: String {
        switch self {
        case .demo: "개발용"
        case .production: "실사용"
        }
    }
}

/// Stable key for a card print. Card names are never identifiers.
public struct CardKey: Hashable, Sendable, Codable, RawRepresentable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }

    public init(source: String, language: String, setID: String, localID: String) {
        self.rawValue = "\(source):\(language):\(setID):\(localID)"
    }

    public var description: String { rawValue }

    /// `source:language:setID:localID` — used when a stored card is no longer in
    /// any catalogue snapshot and only its key remains.
    public var setID: String {
        let parts = rawValue.split(separator: ":", omittingEmptySubsequences: false)
        return parts.count >= 3 ? String(parts[2]) : ""
    }
}
