import Foundation

/// Sets as the screens list them once there are too many for one grid: by
/// series, newest series first, each set followed by the subsets that came in
/// its packs (Trainer Gallery, Shiny Vault …).
public struct SeriesGroup: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var setIDs: [String]

    public init(id: String, name: String, setIDs: [String]) {
        self.id = id
        self.name = name
        self.setIDs = setIDs
    }

    /// Sets the pool does not place in a series (legacy snapshots, or every set
    /// when the pool has no series).
    public static let otherID = "other"
}

extension CatalogLibrary {
    /// Every set in the library, grouped by the series the pool gives its
    /// product. Series follow the pool's declared order reversed (newest
    /// first); sets inside a series go newest release first.
    public func seriesGroups(pool: ResolvedPackPool?) -> [SeriesGroup] {
        var seriesOfSet: [String: String] = [:]
        for candidate in pool?.candidates ?? [] {
            guard let series = candidate.series else { continue }
            for setID in candidate.recipe.setIDs where seriesOfSet[setID] == nil {
                seriesOfSet[setID] = series
            }
        }
        var parents: [String: String] = [:]
        for setID in setIDs {
            if let parent = parentSetID(of: setID), parent != setID { parents[setID] = parent }
        }
        let releases = Dictionary(uniqueKeysWithValues: setIDs.map { ($0, setInfo(for: $0)?.releaseDate ?? "") })
        func release(_ setID: String) -> String { releases[setID] ?? "" }
        func series(of setID: String) -> String {
            seriesOfSet[setID] ?? parents[setID].flatMap { seriesOfSet[$0] } ?? SeriesGroup.otherID
        }

        let mains = setIDs.filter { parents[$0] == nil || !setIDs.contains(parents[$0]!) }
        var members: [String: [String]] = [:]
        for setID in mains.sorted(by: { (release($0), $0) > (release($1), $1) }) {
            let subsets = setIDs.filter { parents[$0] == setID }.sorted()
            members[series(of: setID), default: []] += [setID] + subsets
        }

        var groups: [SeriesGroup] = []
        for declared in (pool?.series ?? []).reversed() {
            guard let ids = members.removeValue(forKey: declared.id), !ids.isEmpty else { continue }
            groups.append(SeriesGroup(id: declared.id, name: declared.name, setIDs: ids))
        }
        // Series a candidate names but the pool does not declare cannot pass
        // `resolve`; anything left is a set outside the pool.
        let rest = members.keys.sorted().flatMap { members[$0] ?? [] }
        if !rest.isEmpty {
            groups.append(SeriesGroup(id: SeriesGroup.otherID, name: groups.isEmpty ? "전체 세트" : "그 밖의 세트", setIDs: rest))
        }
        return groups
    }
}
