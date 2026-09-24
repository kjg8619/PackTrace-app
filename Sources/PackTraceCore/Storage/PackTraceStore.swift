import Foundation

/// All persistent state lives behind this actor: one connection, serialized
/// writes, one transaction per user-visible action. The UI and the RNG never
/// touch SQLite directly.
public actor PackTraceStore {
    public nonisolated let location: StoreLocation
    public nonisolated let library: CatalogLibrary
    public nonisolated let economy: PackEconomy

    /// Catalogue used for new exchanges and for UI lookups.
    public nonisolated var catalog: PackCatalog { library.rewardCatalog() }

    /// Internal rather than private so the usage-source extensions can share
    /// one connection and one transaction; still not part of the public API.
    let database: SQLiteDatabase
    private var isClosed = false

    /// Test-only seam for proving that a failed transaction leaves no partial
    /// rows behind. Never set outside tests.
    #if DEBUG
    /// Internal so the usage extensions can honour the same test hook.
    var injectedFailure: InjectedFailure?

    public func setInjectedFailureForTesting(_ failure: InjectedFailure?) {
        injectedFailure = failure
    }

    /// Test-only: force a large stored remainder so the next award has to prove
    /// it rolls back on integer overflow.
    public func setRewardRemainderForTesting(ruleID: String, remainderTokens: Int) throws {
        try database.run(
            """
            INSERT INTO reward_state (rule_id, realm, remainder_tokens, accepted_tokens, awarded_points, updated_at)
            VALUES (?, ?, ?, 0, 0, ?)
            ON CONFLICT(rule_id) DO UPDATE SET remainder_tokens = excluded.remainder_tokens
            """,
            [.text(ruleID), .text(location.realm.rawValue), .int(remainderTokens), .double(Date().timeIntervalSince1970)]
        )
    }
    #endif

    public init(location: StoreLocation, catalog: PackCatalog, economy: PackEconomy = .v1) throws {
        try self.init(location: location, library: try CatalogLibrary(catalogs: [catalog]), economy: economy)
    }

    public init(location: StoreLocation, library: CatalogLibrary, economy: PackEconomy = .v1) throws {
        try location.prepareDirectories()
        self.location = location
        self.library = library
        self.economy = economy
        self.database = try SQLiteDatabase(path: location.databaseURL.path)
        try Schema.migrate(database)
        for catalog in library.catalogs.values.sorted(by: { $0.catalogVersion < $1.catalogVersion }) {
            try Self.recordCatalogReference(database, catalog: catalog, realm: location.realm)
        }
    }

    private static func recordCatalogReference(
        _ database: SQLiteDatabase,
        catalog: PackCatalog,
        realm: Realm
    ) throws {
        try database.run(
            """
            INSERT INTO catalog_ref (catalog_version, content_hash, realm, loaded_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(catalog_version) DO UPDATE SET
                content_hash = excluded.content_hash,
                loaded_at = excluded.loaded_at
            """,
            [
                .text(catalog.catalogVersion),
                .text(catalog.contentHash),
                .text(realm.rawValue),
                .double(Date().timeIntervalSince1970),
            ]
        )
    }

    /// Closes the connection. The instance must not be used afterwards; a
    /// restore replaces the file and the app opens a fresh store.
    public func close() {
        guard !isClosed else { return }
        isClosed = true
        database.close()
    }

    /// Internal so the usage extensions can share one transaction.
    func requireOpen() throws {
        guard !isClosed else {
            throw PackTraceError.storage("저장소가 닫혔습니다. 복원 후 새로 여세요.")
        }
    }

    // MARK: - Catalogue helpers

    public nonisolated func rewardCandidates() -> [PackProduct] {
        catalog.products.filter(\.isRewardEligible).sorted { $0.packID < $1.packID }
    }

    /// Pool candidates with their exact probabilities (weight / total weight).
    public nonisolated func candidateSummary(
        pool: ResolvedPackPool
    ) -> [(product: PackProduct, probability: Double, catalogVersion: String, recipeVersion: Int)] {
        pool.candidates.map {
            (
                product: $0.product,
                probability: pool.probability(of: $0.product.packID),
                catalogVersion: $0.catalogVersion,
                recipeVersion: $0.recipe.version
            )
        }
    }

    public nonisolated func card(for key: CardKey) -> CardDefinition? {
        library.card(for: key)
    }

    public nonisolated func product(for packID: String) -> PackProduct? {
        library.product(id: packID)
    }

    /// Sets the library knows about, with their supported print counts.
    public nonisolated func setSummaries() -> [(set: CardSetInfo, cards: Int, prints: Int)] {
        library.setIDs.compactMap { setID in
            guard let info = library.setInfo(for: setID) else { return nil }
            let cards = library.cards(inSet: setID)
            return (set: info, cards: cards.count, prints: cards.reduce(0) { $0 + $1.supportedVariants.count })
        }
    }

    // MARK: - Wallet

    public func balance() throws -> Int {
        try database.scalarInt("SELECT COALESCE(SUM(delta_points), 0) FROM wallet_entry") ?? 0
    }

    public func ledger(limit: Int = 100) throws -> [WalletLedgerEntry] {
        try database.query(
            """
            SELECT entry_id, idempotency_key, delta_points, reason, ref, created_at
            FROM wallet_entry ORDER BY created_at DESC, rowid DESC LIMIT ?
            """,
            [.int(limit)]
        ) { statement in
            WalletLedgerEntry(
                id: WalletEntryID(rawValue: statement.text(at: 0)),
                idempotencyKey: statement.text(at: 1),
                deltaPoints: statement.int(at: 2),
                reason: WalletReason(rawValue: statement.text(at: 3)) ?? .packExchange,
                reference: statement.optionalText(at: 4),
                createdAt: Date(timeIntervalSince1970: statement.double(at: 5))
            )
        }
    }

    /// Development grant. Only the demo realm may call this, and the unique
    /// idempotency key means it can be paid at most once per database.
    @discardableResult
    public func grantInitialDemoPoints(now: Date = Date()) throws -> Int? {
        guard location.realm == .demo else { return nil }
        return try database.transaction {
            let key = "demo.grant.v\(economy.version)"
            let existing = try database.scalarInt(
                "SELECT COUNT(*) FROM wallet_entry WHERE idempotency_key = ?",
                [.text(key)]
            )
            guard existing == 0 else { return nil }
            try insertLedgerEntry(
                id: WalletEntryID(),
                idempotencyKey: key,
                deltaPoints: economy.initialDemoGrantPoints,
                reason: .demoInitialGrant,
                reference: nil,
                createdAt: now
            )
            return economy.initialDemoGrantPoints
        }
    }

    /// Internal so the usage extensions can share one transaction.
    func insertLedgerEntry(
        id: WalletEntryID,
        idempotencyKey: String,
        deltaPoints: Int,
        reason: WalletReason,
        reference: String?,
        createdAt: Date
    ) throws {
        try database.run(
            """
            INSERT INTO wallet_entry
                (entry_id, idempotency_key, delta_points, reason, ref, created_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            [
                .text(id.rawValue),
                .text(idempotencyKey),
                .int(deltaPoints),
                .text(reason.rawValue),
                .opt(reference),
                .double(createdAt.timeIntervalSince1970),
            ]
        )
    }

    // MARK: - Exchange

    /// Charges points and creates one sealed pack from the resolved pool, all in
    /// a single transaction. Repeating the same `requestID` returns the stored
    /// result without charging again — even if the active pool has changed or is
    /// no longer usable, because a committed request is answered from its own
    /// record first.
    public func exchangePack(
        pool: ResolvedPackPool,
        requestID: ExchangeRequestID,
        now: Date = Date(),
        seed: UInt64
    ) throws -> ExchangeOutcome {
        try requireOpen()
        let key = "exchange:\(requestID.rawValue)"

        // 1. A committed request is answered from its stored result before the
        //    current pool is looked at.
        if let stored = try packRequest(requestID: requestID) {
            guard stored.fingerprint == requestFingerprint(pool: pool) else {
                throw PackTraceError.exchangeRequestConflict(requestID: requestID.rawValue)
            }
            if let outcome = try existingExchange(idempotencyKey: key) {
                return outcome
            }
        } else if let legacy = try existingExchange(idempotencyKey: key) {
            // Requests committed before the pool existed keep their own result.
            return legacy
        }

        // 2. The pool must be fully usable: no candidate is dropped silently,
        //    and nothing is charged when it is not.
        let candidate = try pool.pick(seed: seed)
        guard candidate.recipe.version > 0, !candidate.product.recipeID.isEmpty else {
            throw PackTraceError.productNotReady(packID: candidate.product.packID)
        }

        do {
            return try performExchange(
                requestID: requestID,
                requestKey: key,
                candidate: candidate,
                poolVersion: pool.poolVersion,
                price: pool.pricePoints,
                fingerprint: requestFingerprint(pool: pool),
                now: now
            )
        } catch let error as PackTraceError {
            // Another connection (a second app instance) may have committed the
            // same request between our read and our write. The unique key means
            // it can only ever be charged once; report that request instead.
            if case .storage(let message) = error, message.contains("UNIQUE constraint failed: wallet_entry.idempotency_key") {
                if let existing = try existingExchange(idempotencyKey: key) {
                    return existing
                }
            }
            throw error
        }
    }

    /// Identity of a request's content: which profile pays and what price it
    /// pays. The pool version is recorded with the request but is *not* part of
    /// the fingerprint, because a retry of the same user action must still
    /// return the original result after the active pool changed or was
    /// disabled. A retry that would charge a different price, or land in a
    /// different profile, is refused as a conflict instead.
    nonisolated func requestFingerprint(pool: ResolvedPackPool) -> String {
        "\(location.realm.rawValue)|\(pool.pricePoints)|\(economy.version)"
    }

    private func performExchange(
        requestID: ExchangeRequestID,
        requestKey key: String,
        candidate: ResolvedPackPool.Candidate,
        poolVersion: String,
        price: Int,
        fingerprint: String,
        now: Date
    ) throws -> ExchangeOutcome {
        return try database.transaction {
            let balance = try database.scalarInt("SELECT COALESCE(SUM(delta_points), 0) FROM wallet_entry") ?? 0
            guard balance >= price else {
                throw PackTraceError.insufficientBalance(required: price, available: balance)
            }

            let instanceID = PackInstanceID()
            let entryID = WalletEntryID()
            let entry = WalletLedgerEntry(
                id: entryID,
                idempotencyKey: key,
                deltaPoints: -price,
                reason: .packExchange,
                reference: instanceID.rawValue,
                createdAt: now
            )
            #if DEBUG
            if injectedFailure == .beforeExchangeCommit {
                throw PackTraceError.injectedFailure("exchange.before-commit")
            }
            #endif
            try insertLedgerEntry(
                id: entryID,
                idempotencyKey: key,
                deltaPoints: -price,
                reason: .packExchange,
                reference: instanceID.rawValue,
                createdAt: now
            )
            try database.run(
                """
                INSERT INTO pack_instance
                    (instance_id, product_id, catalog_version, recipe_version, acquired_at, state,
                     exchange_entry_id, pool_version)
                VALUES (?, ?, ?, ?, ?, 'sealed', ?, ?)
                """,
                [
                    .text(instanceID.rawValue),
                    .text(candidate.product.packID),
                    .text(candidate.catalogVersion),
                    .int(candidate.recipe.version),
                    .double(now.timeIntervalSince1970),
                    .text(entryID.rawValue),
                    .text(poolVersion),
                ]
            )
            try database.run(
                """
                INSERT INTO pack_request
                    (request_id, realm, pool_version, price_points, economy_version, product_id,
                     instance_id, fingerprint, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    .text(requestID.rawValue),
                    .text(location.realm.rawValue),
                    .text(poolVersion),
                    .int(price),
                    .int(economy.version),
                    .text(candidate.product.packID),
                    .text(instanceID.rawValue),
                    .text(fingerprint),
                    .double(now.timeIntervalSince1970),
                ]
            )
            let pack = PackInstanceRecord(
                id: instanceID,
                productID: candidate.product.packID,
                catalogVersion: candidate.catalogVersion,
                recipeVersion: candidate.recipe.version,
                poolVersion: poolVersion,
                acquiredAt: now,
                state: .sealed,
                exchangeEntryID: entryID
            )
            return ExchangeOutcome(
                packInstance: pack,
                ledgerEntry: entry,
                balanceAfter: balance - price,
                reusedExistingRequest: false
            )
        }
    }

    struct StoredPackRequest {
        var requestID: String
        var poolVersion: String
        var productID: String
        var instanceID: String
        var fingerprint: String
        var createdAt: Date
    }

    func packRequest(requestID: ExchangeRequestID) throws -> StoredPackRequest? {
        try database.query(
            """
            SELECT request_id, pool_version, product_id, instance_id, fingerprint, created_at
            FROM pack_request WHERE request_id = ?
            """,
            [.text(requestID.rawValue)]
        ) { statement in
            StoredPackRequest(
                requestID: statement.text(at: 0),
                poolVersion: statement.text(at: 1),
                productID: statement.text(at: 2),
                instanceID: statement.text(at: 3),
                fingerprint: statement.text(at: 4),
                createdAt: Date(timeIntervalSince1970: statement.double(at: 5))
            )
        }.first
    }

    private func existingExchange(idempotencyKey: String) throws -> ExchangeOutcome? {
        let rows = try database.query(
            """
            SELECT p.instance_id, p.product_id, p.catalog_version, p.recipe_version,
                   p.acquired_at, p.state, p.exchange_entry_id, p.pool_version,
                   w.idempotency_key, w.delta_points, w.reason, w.ref, w.created_at,
                   (SELECT COALESCE(SUM(delta_points), 0) FROM wallet_entry)
            FROM wallet_entry w
            JOIN pack_instance p ON p.exchange_entry_id = w.entry_id
            WHERE w.idempotency_key = ?
            """,
            [.text(idempotencyKey)]
        ) { statement in
            let entryID = WalletEntryID(rawValue: statement.text(at: 6))
            return ExchangeOutcome(
                packInstance: PackInstanceRecord(
                    id: PackInstanceID(rawValue: statement.text(at: 0)),
                    productID: statement.text(at: 1),
                    catalogVersion: statement.text(at: 2),
                    recipeVersion: statement.int(at: 3),
                    poolVersion: statement.optionalText(at: 7),
                    acquiredAt: Date(timeIntervalSince1970: statement.double(at: 4)),
                    state: PackState(rawValue: statement.text(at: 5)) ?? .sealed,
                    exchangeEntryID: entryID
                ),
                // Columns 8…13: the ledger entry, then the balance. They were
                // read one column early (from the pack's pool version), so a
                // replayed request came back with a garbled ledger entry and the
                // entry's timestamp as its balance.
                ledgerEntry: WalletLedgerEntry(
                    id: entryID,
                    idempotencyKey: statement.text(at: 8),
                    deltaPoints: statement.int(at: 9),
                    reason: WalletReason(rawValue: statement.text(at: 10)) ?? .packExchange,
                    reference: statement.optionalText(at: 11),
                    createdAt: Date(timeIntervalSince1970: statement.double(at: 12))
                ),
                balanceAfter: statement.int(at: 13),
                reusedExistingRequest: true
            )
        }
        return rows.first
    }

    // MARK: - Vault

    public func packInstances(state: PackState? = nil) throws -> [PackInstanceRecord] {
        var sql = """
        SELECT instance_id, product_id, catalog_version, recipe_version, acquired_at, state, exchange_entry_id,
               pool_version
        FROM pack_instance
        """
        var bindings: [SQLiteValue] = []
        if let state {
            sql += " WHERE state = ?"
            bindings.append(.text(state.rawValue))
        }
        sql += " ORDER BY acquired_at ASC, rowid ASC"
        return try database.query(sql, bindings) { statement in
            PackInstanceRecord(
                id: PackInstanceID(rawValue: statement.text(at: 0)),
                productID: statement.text(at: 1),
                catalogVersion: statement.text(at: 2),
                recipeVersion: statement.int(at: 3),
                poolVersion: statement.optionalText(at: 7),
                acquiredAt: Date(timeIntervalSince1970: statement.double(at: 4)),
                state: PackState(rawValue: statement.text(at: 5)) ?? .sealed,
                exchangeEntryID: WalletEntryID(rawValue: statement.text(at: 6))
            )
        }
    }

    public func sealedPackCount() throws -> Int {
        try database.scalarInt("SELECT COUNT(*) FROM pack_instance WHERE state = 'sealed'") ?? 0
    }

    // MARK: - Opening

    /// Commits the drawn cards first, then reports them. Calling this again for
    /// the same pack returns the stored result instead of drawing again.
    public func openPack(
        instanceID: PackInstanceID,
        now: Date = Date(),
        seed: UInt64
    ) throws -> OpeningRecord {
        try requireOpen()
        if let existing = try opening(forPack: instanceID) {
            return existing
        }
        guard let pack = try packInstances().first(where: { $0.id == instanceID }) else {
            throw PackTraceError.packNotFound(instanceID)
        }
        // A pack always opens with the catalogue and recipe version it was
        // handed out with, never with a newer one from a refreshed catalogue.
        guard let pinned = library.catalog(version: pack.catalogVersion) else {
            throw PackTraceError.catalogNotFound(pack.catalogVersion)
        }
        guard let product = pinned.product(id: pack.productID) else {
            throw PackTraceError.productNotReady(packID: pack.productID)
        }
        guard let recipe = pinned.recipe(id: product.recipeID), recipe.version == pack.recipeVersion else {
            throw PackTraceError.productNotReady(packID: pack.productID)
        }
        let cards = try PackDrawer.draw(recipe: recipe, catalog: pinned, seed: seed)
        let cardsByKey = Dictionary(uniqueKeysWithValues: pinned.cards.map { ($0.key, $0) })
        for card in cards where cardsByKey[card.cardKey] == nil {
            throw PackTraceError.unknownCard(card.cardKey)
        }
        let resultJSON = try Self.encodeCards(cards)

        do {
            return try commitOpening(instanceID: instanceID, cards: cards, resultJSON: resultJSON, now: now)
        } catch let error as PackTraceError {
            if case .storage(let message) = error, message.contains("UNIQUE constraint failed: opening.pack_instance_id") {
                if let existing = try opening(forPack: instanceID) {
                    return existing
                }
            }
            throw error
        }
    }

    private func commitOpening(
        instanceID: PackInstanceID,
        cards: [DrawnCard],
        resultJSON: String,
        now: Date
    ) throws -> OpeningRecord {
        return try database.transaction {
            let openingID = OpeningID()
            #if DEBUG
            if injectedFailure == .beforeOpeningCommit {
                throw PackTraceError.injectedFailure("opening.before-commit")
            }
            #endif
            try database.run(
                """
                INSERT INTO opening
                    (opening_id, pack_instance_id, created_at, completed_at, revealed_count, result_json)
                VALUES (?, ?, ?, NULL, 0, ?)
                """,
                [
                    .text(openingID.rawValue),
                    .text(instanceID.rawValue),
                    .double(now.timeIntervalSince1970),
                    .text(resultJSON),
                ]
            )
            for card in cards {
                try database.run(
                    """
                    INSERT INTO owned_card_instance
                        (instance_id, card_key, variant, opening_id, acquired_at)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                    [
                        .text(OwnedCardID().rawValue),
                        .text(card.cardKey.rawValue),
                        .text(card.variant.rawValue),
                        .text(openingID.rawValue),
                        .double(now.timeIntervalSince1970),
                    ]
                )
            }
            try database.run(
                "UPDATE pack_instance SET state = 'opened' WHERE instance_id = ?",
                [.text(instanceID.rawValue)]
            )
            return OpeningRecord(
                id: openingID,
                packInstanceID: instanceID,
                createdAt: now,
                completedAt: nil,
                revealedCount: 0,
                cards: cards
            )
        }
    }

    public func opening(forPack instanceID: PackInstanceID) throws -> OpeningRecord? {
        try database.query(
            """
            SELECT opening_id, pack_instance_id, created_at, completed_at, revealed_count, result_json
            FROM opening WHERE pack_instance_id = ?
            """,
            [.text(instanceID.rawValue)],
            map: Self.decodeOpening
        ).first
    }

    public func opening(id: OpeningID) throws -> OpeningRecord? {
        try database.query(
            """
            SELECT opening_id, pack_instance_id, created_at, completed_at, revealed_count, result_json
            FROM opening WHERE opening_id = ?
            """,
            [.text(id.rawValue)],
            map: Self.decodeOpening
        ).first
    }

    public func openings() throws -> [OpeningRecord] {
        try database.query(
            """
            SELECT opening_id, pack_instance_id, created_at, completed_at, revealed_count, result_json
            FROM opening ORDER BY created_at ASC, rowid ASC
            """,
            map: Self.decodeOpening
        )
    }

    /// Records reveal progress. Called once per revealed card so a restart can
    /// resume where the user stopped.
    public func setRevealedCount(openingID: OpeningID, count: Int, now: Date = Date()) throws -> OpeningRecord {
        try requireOpen()
        guard let stored = try opening(id: openingID) else {
            throw PackTraceError.openingNotFound(openingID)
        }
        let clamped = min(max(count, 0), stored.cards.count)
        try database.transaction {
            try database.run(
                "UPDATE opening SET revealed_count = ? WHERE opening_id = ?",
                [.int(clamped), .text(openingID.rawValue)]
            )
            if clamped >= stored.cards.count {
                try database.run(
                    "UPDATE opening SET completed_at = COALESCE(completed_at, ?) WHERE opening_id = ?",
                    [.double(now.timeIntervalSince1970), .text(openingID.rawValue)]
                )
            }
        }
        guard let updated = try opening(id: openingID) else {
            throw PackTraceError.openingNotFound(openingID)
        }
        return updated
    }

    /// Packs that were opened but not fully revealed, so the UI can resume the
    /// same stored result after a restart.
    public func unfinishedOpenings() throws -> [OpeningRecord] {
        try openings().filter { !$0.isComplete }
    }

    // MARK: - Binder

    /// When each copy of one print was obtained, oldest first.
    public func acquisitionDates(cardKey: CardKey, variant: CardVariant) throws -> [Date] {
        try database.query(
            """
            SELECT acquired_at FROM owned_card_instance
            WHERE card_key = ? AND variant = ?
            ORDER BY acquired_at ASC, rowid ASC
            """,
            [.text(cardKey.rawValue), .text(variant.rawValue)]
        ) { Date(timeIntervalSince1970: $0.double(at: 0)) }
    }

    public func ownedCardInstances() throws -> [OwnedCardRecord] {
        let cardsByKey = library.cardsByKey
        return try database.query(
            """
            SELECT instance_id, card_key, variant, opening_id, acquired_at
            FROM owned_card_instance ORDER BY acquired_at ASC, rowid ASC
            """
        ) { statement in
            let key = CardKey(rawValue: statement.text(at: 1))
            return OwnedCardRecord(
                id: OwnedCardID(rawValue: statement.text(at: 0)),
                cardKey: key,
                variant: CardVariant(rawValue: statement.text(at: 2)) ?? .normal,
                openingID: OpeningID(rawValue: statement.text(at: 3)),
                acquiredAt: Date(timeIntervalSince1970: statement.double(at: 4)),
                setID: cardsByKey[key]?.setID ?? key.setID
            )
        }
    }

    /// Binder rows for one variant view. Defaults to the base print of each
    /// card; reverse and foil prints are counted separately.
    public func binderEntries(setID: String, variant: CardVariant? = nil) throws -> [BinderEntry] {
        binderEntries(setID: setID, variant: variant, owned: try ownedCardInstances())
    }

    /// Cards of every set matching the query, as binder rows (one per print
    /// the app collects), sorted by name then set. Every word of the query
    /// must appear in the card's name, its set's name or id, or its number;
    /// case and accents are ignored ("pokemon" finds "Pokémon", "sv01 25"
    /// finds that card). `total` counts every match beyond `limit`.
    public func searchBinder(query: String, limit: Int = 300) throws -> (entries: [BinderEntry], total: Int) {
        func fold(_ text: String) -> String {
            text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        }
        let words = fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return ([], 0) }
        var setNames: [String: String] = [:]
        let matches = library.cards.filter { card in
            let setName = setNames[card.setID] ?? {
                let name = fold(library.setInfo(for: card.setID)?.name ?? "")
                setNames[card.setID] = name
                return name
            }()
            let haystack = "\(fold(card.name)) \(setName) \(fold(card.setID)) \(fold(card.localID))"
            return words.allSatisfy { haystack.contains($0) }
        }
        .sorted { ($0.name, $0.setID, $0.localID) < ($1.name, $1.setID, $1.localID) }

        var quantities: [String: (count: Int, first: Date)] = [:]
        for record in try ownedCardInstances() {
            let key = "\(record.cardKey.rawValue)#\(record.variant.rawValue)"
            if var current = quantities[key] {
                current.count += 1
                current.first = min(current.first, record.acquiredAt)
                quantities[key] = current
            } else {
                quantities[key] = (1, record.acquiredAt)
            }
        }
        var seen = Set<String>()
        var entries: [BinderEntry] = []
        var total = 0
        for card in matches {
            for variant in card.supportedVariants {
                total += 1
                if entries.count < limit {
                    entries.append(entry(for: card, variant: variant, quantities: quantities, seen: &seen))
                }
            }
        }
        return (entries, total)
    }

    private func binderEntries(setID: String, variant: CardVariant?, owned: [OwnedCardRecord]) -> [BinderEntry] {
        let targetSet = setID
        var quantities: [String: (count: Int, first: Date)] = [:]
        for record in owned where record.setID == targetSet {
            if let variant, record.variant != variant { continue }
            let key = "\(record.cardKey.rawValue)#\(record.variant.rawValue)"
            if var current = quantities[key] {
                current.count += 1
                current.first = min(current.first, record.acquiredAt)
                quantities[key] = current
            } else {
                quantities[key] = (1, record.acquiredAt)
            }
        }

        var seen = Set<String>()
        var entries: [BinderEntry] = []
        for card in library.cards(inSet: targetSet) {
            for variant in card.supportedVariants {
                entries.append(entry(for: card, variant: variant, quantities: quantities, seen: &seen))
            }
        }
        // Owned prints that the catalogue no longer lists still belong to the user.
        for record in owned where record.setID == targetSet {
            let key = "\(record.cardKey.rawValue)#\(record.variant.rawValue)"
            guard !seen.contains(key), let card = library.card(for: record.cardKey) else { continue }
            seen.insert(key)
            entries.append(entry(for: card, variant: record.variant, quantities: quantities, seen: &seen))
        }
        return entries
    }

    private func entry(
        for card: CardDefinition,
        variant: CardVariant,
        quantities: [String: (count: Int, first: Date)],
        seen: inout Set<String>
    ) -> BinderEntry {
        let key = "\(card.key.rawValue)#\(variant.rawValue)"
        seen.insert(key)
        let record = quantities[key]
        return BinderEntry(
            card: card,
            variant: variant,
            quantity: record?.count ?? 0,
            firstAcquiredAt: record?.first ?? .distantPast
        )
    }

    /// Prints whose earliest owned copy comes from this opening. Used to mark
    /// "새 카드" while revealing without a second draw or a stored guess.
    public func firstTimePrints(openingID: OpeningID) throws -> Set<String> {
        let rows = try database.query(
            """
            SELECT o.card_key, o.variant
            FROM owned_card_instance o
            WHERE o.opening_id = ?
              AND NOT EXISTS (
                SELECT 1 FROM owned_card_instance x
                WHERE x.card_key = o.card_key
                  AND x.variant = o.variant
                  AND (x.acquired_at < o.acquired_at
                       OR (x.acquired_at = o.acquired_at AND x.rowid < o.rowid))
              )
            """,
            [.text(openingID.rawValue)]
        ) { statement in
            "\(statement.text(at: 0))#\(statement.text(at: 1))"
        }
        return Set(rows)
    }

    public func binderProgress(setID: String) throws -> BinderProgress {
        Self.progress(of: try binderEntries(setID: setID))
    }

    /// Progress of every set the library knows, from one read of the owned
    /// cards (the per-set call reads them all again for each set).
    public func binderProgressBySet() throws -> [String: BinderProgress] {
        let owned = Dictionary(grouping: try ownedCardInstances(), by: \.setID)
        var result: [String: BinderProgress] = [:]
        for setID in library.setIDs {
            result[setID] = Self.progress(of: binderEntries(setID: setID, variant: nil, owned: owned[setID] ?? []))
        }
        return result
    }

    private static func progress(of entries: [BinderEntry]) -> BinderProgress {
        let ownedUnique = entries.filter { $0.quantity > 0 }.count
        let totalCopies = entries.reduce(0) { $0 + $1.quantity }
        return BinderProgress(
            ownedUniquePrints: ownedUnique,
            totalPrints: entries.count,
            totalCopies: totalCopies
        )
    }

    // MARK: - Usage collection

    /// The single OMP source for this realm, if one was connected.
    ///
    /// OMP only: it used to return the newest connected row of any tool, so the
    /// OMP collector's scan time and diagnostics landed on whichever tool had
    /// been connected last.
    public func usageSource() throws -> UsageSourceRecord? {
        try usageSourceQuery(where: "WHERE status != 'unconnected' AND tool_kind = 'omp'")
    }

    /// The most recent OMP source row even when it is disconnected, so the app
    /// can offer "reconnect" with the stored path (a restore leaves the profile
    /// in exactly that state).
    public func latestUsageSource() throws -> UsageSourceRecord? {
        try usageSourceQuery(where: "WHERE tool_kind = 'omp'")
    }

    private func usageSourceQuery(where clause: String) throws -> UsageSourceRecord? {
        try database.query(
            """
            SELECT source_id, realm, root_path, connected_at, baseline_completed_at,
                   paused, last_scan_at, status, last_reason, tool_kind, tool_version, format_version
            FROM usage_source
            \(clause)
            ORDER BY connected_at DESC LIMIT 1
            """
        ) { statement in
            UsageSourceRecord(
                sourceID: statement.text(at: 0),
                realm: Realm(rawValue: statement.text(at: 1)) ?? self.location.realm,
                tool: UsageToolKind(rawValue: statement.text(at: 9)) ?? .omp,
                toolVersion: statement.optionalText(at: 10),
                formatVersion: statement.optionalText(at: 11),
                rootPath: statement.text(at: 2),
                connectedAt: Date(timeIntervalSince1970: statement.double(at: 3)),
                baselineCompletedAt: statement.optionalText(at: 4).flatMap { Double($0) }.map(Date.init(timeIntervalSince1970:)),
                isPaused: statement.int(at: 5) != 0,
                lastScanAt: statement.optionalText(at: 6).flatMap { Double($0) }.map(Date.init(timeIntervalSince1970:)),
                status: UsageSourceStatus(rawValue: statement.text(at: 7)) ?? .unconnected,
                lastReason: statement.optionalText(at: 8)
            )
        }.first
    }

    /// Creates or reuses the source row. Re-selecting the same root keeps the
    /// existing connection instead of resetting the baseline.
    @discardableResult
    public func connectUsageSource(rootPath: String, now: Date = Date()) throws -> UsageSourceRecord {
        if let existing = try usageSource(tool: .omp) {
            if existing.rootPath == rootPath {
                try database.run(
                    "UPDATE usage_source SET status = ?, last_reason = NULL WHERE source_id = ?",
                    [.text(existing.status == .paused ? UsageSourceStatus.paused.rawValue : existing.status.rawValue),
                     .text(existing.sourceID)]
                )
                return try usageSource(tool: .omp) ?? existing
            }
            // A different root becomes the active connection. The previous
            // source row, its checkpoints and its events stay on disk: event
            // identities are global, so nothing can be paid twice.
            try database.run(
                "UPDATE usage_source SET status = ?, last_reason = ? WHERE source_id = ?",
                [
                    .text(UsageSourceStatus.unconnected.rawValue),
                    .text("replaced_by_another_root"),
                    .text(existing.sourceID),
                ]
            )
        }
        let sourceID = UUID().uuidString.lowercased()
        try database.run(
            """
            INSERT INTO usage_source (source_id, realm, root_path, connected_at, baseline_completed_at,
                                      paused, last_scan_at, status, last_reason)
            VALUES (?, ?, ?, ?, NULL, 0, NULL, ?, NULL)
            """,
            [
                .text(sourceID),
                .text(location.realm.rawValue),
                .text(rootPath),
                .double(now.timeIntervalSince1970),
                .text(UsageSourceStatus.baselining.rawValue),
            ]
        )
        guard let record = try usageSource(tool: .omp) else {
            throw PackTraceError.storage("usage source insert failed")
        }
        return record
    }

    public func setUsageSourceStatus(
        _ status: UsageSourceStatus,
        reason: String? = nil,
        paused: Bool? = nil,
        now: Date = Date()
    ) throws {
        guard let source = try usageSource(tool: .omp) else { return }
        var sql = "UPDATE usage_source SET status = ?, last_reason = ?"
        var bindings: [SQLiteValue] = [.text(status.rawValue), .opt(reason)]
        if let paused {
            sql += ", paused = ?"
            bindings.append(.int(paused ? 1 : 0))
        }
        sql += " WHERE source_id = ?"
        bindings.append(.text(source.sourceID))
        try database.run(sql, bindings)
    }

    public func setUsageSourcePaused(_ paused: Bool, now: Date = Date()) throws {
        guard let source = try usageSource(tool: .omp) else { return }
        try database.run(
            "UPDATE usage_source SET paused = ?, status = ? WHERE source_id = ?",
            [
                .int(paused ? 1 : 0),
                .text(paused ? UsageSourceStatus.paused.rawValue : UsageSourceStatus.collecting.rawValue),
                .text(source.sourceID),
            ]
        )
    }

    public func markUsageSourceBaselined(now: Date = Date()) throws {
        guard let source = try usageSource(tool: .omp) else { return }
        try database.run(
            "UPDATE usage_source SET baseline_completed_at = ?, status = ?, last_reason = NULL WHERE source_id = ?",
            [.double(now.timeIntervalSince1970), .text(UsageSourceStatus.collecting.rawValue), .text(source.sourceID)]
        )
    }

    public func usageCheckpoints(sourceID: String? = nil) throws -> [UsageFileCheckpoint] {
        var sql = """
            SELECT relative_path, device_id, inode, byte_offset, baseline_offset, baseline_done,
                   file_size, status, reason, updated_at
            FROM usage_file_checkpoint
            """
        var bindings: [SQLiteValue] = []
        if let sourceID {
            sql += " WHERE source_id = ?"
            bindings.append(.text(sourceID))
        }
        return try database.query(sql, bindings) { statement in
            UsageFileCheckpoint(
                relativePath: statement.text(at: 0),
                deviceID: UInt64(statement.int(at: 1)),
                inode: UInt64(statement.int(at: 2)),
                byteOffset: Int64(statement.int(at: 3)),
                baselineOffset: Int64(statement.int(at: 4)),
                baselineDone: statement.int(at: 5) != 0,
                fileSize: Int64(statement.int(at: 6)),
                status: UsageFileStatus(rawValue: statement.text(at: 7)) ?? .ok,
                reason: statement.optionalText(at: 8),
                updatedAt: Date(timeIntervalSince1970: statement.double(at: 9))
            )
        }
    }

    /// Records one slice of parsed records and, atomically with it, the reward
    /// that this slice earned and the read positions it consumed.
    ///
    /// Order inside the transaction: identities first (baseline/unsupported/
    /// duplicate excluded before any arithmetic), then the reward arithmetic,
    /// then the ledger entry, then the checkpoints. A failure anywhere leaves
    /// the wallet, the remainder and the checkpoints untouched.
    @discardableResult
    public func applyUsageBatch(
        sourceID: String,
        baseline: Bool,
        entries: [UsageBatchEntry],
        checkpoints: [UsageFileCheckpoint],
        cursors: [UsageCursor] = [],
        sessions: [UsageSessionObservation] = [],
        run: UsageScanRunSummary,
        sessionHeader: OMPLogParser.SessionHeader? = nil,
        rule: UsageRewardRule = .ompNonCacheV1,
        recordRun: Bool = true,
        now: Date = Date()
    ) throws -> UsageBatchResult {
        try requireOpen()
        return try database.transaction {
            var result = UsageBatchResult()
            if let sessionHeader {
                try upsertUsageSession(sourceID: sourceID, header: sessionHeader, now: now)
            }
            for session in sessions {
                try upsertUsageSession(sourceID: sourceID, observation: session, now: now)
            }
            #if DEBUG
            if injectedFailure == .beforeUsageBatchCommit {
                throw PackTraceError.injectedFailure("usage.before-commit")
            }
            #endif

            var acceptedEventIDs: [String] = []
            var rejectCounts: [UsageRejectionReason: Int] = [:]
            for entry in entries {
                guard let event = entry.event else {
                    // No stable identity: counted per reason so diagnostics can
                    // report it without storing anything about the record.
                    if let reason = entry.reason {
                        rejectCounts[reason, default: 0] += 1
                    }
                    continue
                }
                let status = baseline ? UsageEventStatus.baseline : entry.status

                // Already recorded under this exact key.
                if let existing = try existingUsageEvent(event.id) {
                    if existing.fingerprint == event.fingerprint {
                        result.duplicates += 1
                    } else {
                        result.conflicts += 1
                        try recordUsageConflict(
                            eventID: event.id,
                            existing: existing,
                            incoming: event,
                            now: now
                        )
                    }
                    continue
                }

                // The adapter can sometimes prove that two records are the same
                // real call (a provider request id, for example). That check
                // comes first because provider + response id is only unique
                // within one provider's own naming, while a call key is meant to
                // survive a tool boundary.
                if let callKey = event.callKey, !callKey.isEmpty,
                   let original = try existingCallKey(callKey) {
                    result.duplicates += 1
                    try recordUsageAlias(
                        eventID: event.id,
                        originalEventID: original.eventID,
                        reason: original.fingerprint == event.fingerprint
                            ? UsageRejectionReason.duplicateCall
                            : UsageRejectionReason.identityConflict,
                        sessionID: event.sessionID,
                        now: now
                    )
                    if original.fingerprint != event.fingerprint {
                        result.conflicts += 1
                    }
                    continue
                }

                // Already recorded under a *different* key: the same provider
                // call reached us through another session (fork/import). It is
                // never paid twice, and the origin is recorded for diagnostics.
                if let alias = try existingUsageEventID(provider: event.provider, responseID: event.responseID) {
                    result.duplicates += 1
                    try recordUsageAlias(
                        eventID: event.id,
                        originalEventID: alias.eventID,
                        reason: alias.fingerprint == event.fingerprint
                            ? UsageRejectionReason.duplicateOriginalCall
                            : UsageRejectionReason.identityConflict,
                        sessionID: event.sessionID,
                        now: now
                    )
                    if alias.fingerprint != event.fingerprint {
                        result.conflicts += 1
                    }
                    continue
                }
                if let knownAlias = try usageAliasTarget(for: event.id) {
                    result.duplicates += 1
                    _ = knownAlias
                    continue
                }

                try insertUsageEvent(
                    event,
                    sourceID: sourceID,
                    status: status,
                    reason: entry.reason,
                    rule: rule,
                    now: now
                )
                result.inserted += 1
                if status == .accepted {
                    guard let accepted = rule.acceptedTokens(for: event) else {
                        throw PackTraceError.usageRewardOverflow(ruleID: rule.ruleID)
                    }
                    result.acceptedEvents += 1
                    let (sum, overflow) = result.acceptedTokens.addingReportingOverflow(accepted)
                    guard !overflow else { throw PackTraceError.usageRewardOverflow(ruleID: rule.ruleID) }
                    result.acceptedTokens = sum
                    acceptedEventIDs.append(event.id.rawValue)
                }
            }

            if result.duplicates > 0 {
                try bumpUsageCounter("duplicate_events", by: result.duplicates, now: now)
            }
            if result.conflicts > 0 {
                try bumpUsageCounter("conflict_events", by: result.conflicts, now: now)
            }
            for (reason, count) in rejectCounts {
                try database.run(
                    """
                    INSERT INTO usage_reject_stat (reason, count, updated_at) VALUES (?, ?, ?)
                    ON CONFLICT(reason) DO UPDATE SET count = count + excluded.count,
                                                      updated_at = excluded.updated_at
                    """,
                    [.text(reason.rawValue), .int(count), .double(now.timeIntervalSince1970)]
                )
            }

            if baseline {
                result.remainderTokens = try rewardState(ruleID: rule.ruleID)?.remainderTokens ?? 0
            } else if result.acceptedTokens > 0 {
                let award = try awardUsageTokens(
                    rule: rule,
                    newAcceptedTokens: result.acceptedTokens,
                    acceptedEventIDs: acceptedEventIDs,
                    now: now
                )
                result.pointsAwarded = award.points
                result.remainderTokens = award.remainderTokens
                result.awardEntryID = award.entryID
            } else {
                result.remainderTokens = try rewardState(ruleID: rule.ruleID)?.remainderTokens ?? 0
            }

            for checkpoint in checkpoints {
                try upsertUsageCheckpoint(sourceID: sourceID, checkpoint: checkpoint)
            }
            for cursor in cursors {
                try upsertUsageCursor(sourceID: sourceID, cursor: cursor)
            }

            if recordRun {
                var summary = run
                summary.inserted = result.inserted
                summary.duplicates = result.duplicates
                summary.conflicts = result.conflicts
                summary.acceptedTokens = result.acceptedTokens
                summary.pointsAwarded = result.pointsAwarded
                summary.baseline = baseline
                try insertUsageScanRun(summary, sourceID: sourceID)
            }
            return result
        }
    }

    /// Records the observed session, including the fork origin when the log
    /// carries one. Diagnostics only: no reward decision depends on it.
    private func upsertUsageSession(
        sourceID: String,
        header: OMPLogParser.SessionHeader,
        now: Date
    ) throws {
        try database.run(
            """
            INSERT INTO usage_session (session_id, source_id, parent_session, schema_version, first_seen_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(session_id) DO UPDATE SET
                parent_session = COALESCE(excluded.parent_session, usage_session.parent_session),
                schema_version = COALESCE(excluded.schema_version, usage_session.schema_version)
            """,
            [
                .text(header.id),
                .text(sourceID),
                .opt(header.parentSession),
                .int(header.version),
                .double(now.timeIntervalSince1970),
            ]
        )
    }

    private struct OriginalCallMatch {
        var eventID: String
        var fingerprint: String
    }

    /// Looks up an already recorded call by provider + response id, whichever
    /// session it came from.
    private func existingUsageEventID(provider: String, responseID: String) throws -> OriginalCallMatch? {
        try database.query(
            "SELECT event_id, fingerprint FROM usage_event WHERE provider = ? AND response_id = ? LIMIT 1",
            [.text(provider), .text(responseID)]
        ) { statement in
            OriginalCallMatch(eventID: statement.text(at: 0), fingerprint: statement.text(at: 1))
        }.first
    }

    private func usageAliasTarget(for eventID: UsageEventID) throws -> String? {
        try database.scalarInt("SELECT 1 FROM usage_event_alias WHERE event_id = ?", [.text(eventID.rawValue)])
            .map { _ in eventID.rawValue }
    }

    private func recordUsageAlias(
        eventID: UsageEventID,
        originalEventID: String,
        reason: UsageRejectionReason,
        sessionID: String,
        now: Date
    ) throws {
        try database.run(
            """
            INSERT INTO usage_event_alias (event_id, original_event_id, reason, session_id, first_seen_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(event_id) DO UPDATE SET
                original_event_id = excluded.original_event_id,
                reason = excluded.reason
            """,
            [
                .text(eventID.rawValue),
                .text(originalEventID),
                .text(reason.rawValue),
                .text(sessionID),
                .double(now.timeIntervalSince1970),
            ]
        )
    }

    private struct ExistingUsageEvent {
        var fingerprint: String
        var status: String
        var input: Int
        var output: Int
        var cacheRead: Int
        var cacheWrite: Int
    }

    private func existingUsageEvent(_ id: UsageEventID) throws -> ExistingUsageEvent? {
        try database.query(
            "SELECT fingerprint, status, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens FROM usage_event WHERE event_id = ?",
            [.text(id.rawValue)]
        ) { statement in
            ExistingUsageEvent(
                fingerprint: statement.text(at: 0),
                status: statement.text(at: 1),
                input: statement.int(at: 2),
                output: statement.int(at: 3),
                cacheRead: statement.int(at: 4),
                cacheWrite: statement.int(at: 5)
            )
        }.first
    }

    private func recordUsageConflict(
        eventID: UsageEventID,
        existing: ExistingUsageEvent,
        incoming: UsageEvent,
        now: Date
    ) throws {
        var differing: [String] = []
        if existing.input != incoming.inputTokens { differing.append("input") }
        if existing.output != incoming.outputTokens { differing.append("output") }
        if existing.cacheRead != incoming.cacheReadTokens { differing.append("cacheRead") }
        if existing.cacheWrite != incoming.cacheWriteTokens { differing.append("cacheWrite") }
        if differing.isEmpty { differing.append("metadata") }
        try database.run(
            """
            INSERT INTO usage_conflict (event_id, detected_at, differing_fields) VALUES (?, ?, ?)
            ON CONFLICT(event_id) DO UPDATE SET detected_at = excluded.detected_at,
                                                differing_fields = excluded.differing_fields
            """,
            [.text(eventID.rawValue), .double(now.timeIntervalSince1970), .text(differing.joined(separator: ","))]
        )
    }

    private func insertUsageEvent(
        _ event: UsageEvent,
        sourceID: String,
        status: UsageEventStatus,
        reason: UsageRejectionReason?,
        rule: UsageRewardRule,
        now: Date
    ) throws {
        let accepted = status == .accepted
            ? (rule.acceptedTokens(for: event) ?? 0)
            : 0
        try database.run(
            """
            INSERT INTO usage_event (
                event_id, source_id, session_id, response_id, provider, model, stop_reason,
                occurred_at, completed_at, input_tokens, output_tokens, cache_read_tokens,
                cache_write_tokens, accepted_tokens, status, reason, fingerprint, first_seen_at,
                reasoning_tokens, normalization_version, call_key
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(event.id.rawValue),
                .text(sourceID),
                .text(event.sessionID),
                .text(event.responseID),
                .text(event.provider),
                .text(event.model),
                .text(event.stopReason),
                .double(Double(event.occurredAtMilliseconds) / 1000),
                event.completedAtMilliseconds.map { SQLiteValue.double(Double($0) / 1000) } ?? .null,
                .int(event.inputTokens),
                .int(event.outputTokens),
                .int(event.cacheReadTokens),
                .int(event.cacheWriteTokens),
                .int(accepted),
                .text(status.rawValue),
                .opt(reason?.rawValue),
                .text(event.fingerprint),
                .double(now.timeIntervalSince1970),
                event.reasoningTokens.map { SQLiteValue.int($0) } ?? .null,
                .int(event.normalizationVersion),
                event.callKey.map { SQLiteValue.text($0) } ?? .null,
            ]
        )
    }

    /// Looks up a real call by the tool-independent key the adapter supplied.
    private func existingCallKey(_ callKey: String) throws -> OriginalCallMatch? {
        try database.query(
            "SELECT event_id, fingerprint FROM usage_event WHERE call_key = ? LIMIT 1",
            [.text(callKey)]
        ) { statement in
            OriginalCallMatch(eventID: statement.text(at: 0), fingerprint: statement.text(at: 1))
        }.first
    }

    /// Session observation from an adapter that is not the OMP log reader.
    private func upsertUsageSession(
        sourceID: String,
        observation: UsageSessionObservation,
        now: Date
    ) throws {
        try database.run(
            """
            INSERT INTO usage_session (session_id, source_id, parent_session, schema_version, first_seen_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(session_id) DO UPDATE SET
                parent_session = COALESCE(excluded.parent_session, usage_session.parent_session),
                schema_version = COALESCE(excluded.schema_version, usage_session.schema_version)
            """,
            [
                .text(observation.sessionID),
                .text(sourceID),
                .opt(observation.parentSessionID),
                observation.schemaVersion.map { SQLiteValue.int($0) } ?? .null,
                .double(now.timeIntervalSince1970),
            ]
        )
    }

    /// Cursors for sources whose position is not a byte offset (a database row
    /// order, for example). Kept apart from file checkpoints on purpose.
    func upsertUsageCursor(sourceID: String, cursor: UsageCursor) throws {
        try database.run(
            """
            INSERT INTO usage_cursor (source_id, cursor_key, kind, payload, updated_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(source_id, cursor_key) DO UPDATE SET
                kind = excluded.kind,
                payload = excluded.payload,
                updated_at = excluded.updated_at
            """,
            [
                .text(sourceID),
                .text(cursor.cursorKey),
                .text(cursor.kind.rawValue),
                .text(cursor.payload),
                .double(cursor.updatedAt.timeIntervalSince1970),
            ]
        )
    }

    private func upsertUsageCheckpoint(sourceID: String, checkpoint: UsageFileCheckpoint) throws {
        try database.run(
            """
            INSERT INTO usage_file_checkpoint (
                source_id, relative_path, device_id, inode, byte_offset, baseline_offset,
                baseline_done, file_size, status, reason, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(source_id, relative_path) DO UPDATE SET
                device_id = excluded.device_id,
                inode = excluded.inode,
                byte_offset = excluded.byte_offset,
                baseline_offset = excluded.baseline_offset,
                baseline_done = excluded.baseline_done,
                file_size = excluded.file_size,
                status = excluded.status,
                reason = excluded.reason,
                updated_at = excluded.updated_at
            """,
            [
                .text(sourceID),
                .text(checkpoint.relativePath),
                .int(Int(checkpoint.deviceID)),
                .int(Int(checkpoint.inode)),
                .int(Int(checkpoint.byteOffset)),
                .int(Int(checkpoint.baselineOffset)),
                .int(checkpoint.baselineDone ? 1 : 0),
                .int(Int(checkpoint.fileSize)),
                .text(checkpoint.status.rawValue),
                .opt(checkpoint.reason),
                .double(checkpoint.updatedAt.timeIntervalSince1970),
            ]
        )
    }

    private func rewardState(ruleID: String) throws -> (remainderTokens: Int, acceptedTokens: Int, awardedPoints: Int)? {
        try database.query(
            "SELECT remainder_tokens, accepted_tokens, awarded_points FROM reward_state WHERE rule_id = ?",
            [.text(ruleID)]
        ) { statement in
            (statement.int(at: 0), statement.int(at: 1), statement.int(at: 2))
        }.first
    }

    private struct AwardOutcome {
        var points: Int
        var remainderTokens: Int
        var entryID: WalletEntryID?
    }

    /// Integer conversion with the remainder carried forward. Checked: an
    /// overflow aborts the whole batch instead of paying a wrong amount.
    private func awardUsageTokens(
        rule: UsageRewardRule,
        newAcceptedTokens: Int,
        acceptedEventIDs: [String],
        now: Date
    ) throws -> AwardOutcome {
        let state = try rewardState(ruleID: rule.ruleID)
        let storedRemainder = state?.remainderTokens ?? 0
        let storedAccepted = state?.acceptedTokens ?? 0
        let storedPoints = state?.awardedPoints ?? 0

        let (total, overflow) = storedRemainder.addingReportingOverflow(newAcceptedTokens)
        guard !overflow else { throw PackTraceError.usageRewardOverflow(ruleID: rule.ruleID) }
        let (totalAccepted, acceptedOverflow) = storedAccepted.addingReportingOverflow(newAcceptedTokens)
        guard !acceptedOverflow else { throw PackTraceError.usageRewardOverflow(ruleID: rule.ruleID) }
        let (points, remainder) = rule.convert(totalAcceptedTokens: total)
        let (totalPoints, pointsOverflow) = storedPoints.addingReportingOverflow(points)
        guard !pointsOverflow else { throw PackTraceError.usageRewardOverflow(ruleID: rule.ruleID) }

        var entryID: WalletEntryID?
        if points > 0 {
            let seq = try database.scalarInt(
                "SELECT COALESCE(MAX(seq), 0) + 1 FROM usage_award WHERE rule_id = ? AND realm = ?",
                [.text(rule.ruleID), .text(location.realm.rawValue)]
            ) ?? 1
            let id = WalletEntryID()
            try insertLedgerEntry(
                id: id,
                idempotencyKey: "usage.award.\(rule.ruleID).\(location.realm.rawValue).\(seq)",
                deltaPoints: points,
                reason: .usageReward,
                reference: rule.ruleID,
                createdAt: now
            )
            try database.run(
                """
                INSERT INTO usage_award (award_id, rule_id, realm, seq, accepted_tokens, points, entry_id, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    .text(UUID().uuidString.lowercased()),
                    .text(rule.ruleID),
                    .text(location.realm.rawValue),
                    .int(seq),
                    .int(newAcceptedTokens),
                    .int(points),
                    .text(id.rawValue),
                    .double(now.timeIntervalSince1970),
                ]
            )
            entryID = id
            if !acceptedEventIDs.isEmpty {
                let placeholders = Array(repeating: "?", count: acceptedEventIDs.count).joined(separator: ",")
                try database.run(
                    "UPDATE usage_event SET award_entry_id = ? WHERE event_id IN (\(placeholders))",
                    [.text(id.rawValue)] + acceptedEventIDs.map { SQLiteValue.text($0) }
                )
            }
        }

        try database.run(
            """
            INSERT INTO reward_state (rule_id, realm, remainder_tokens, accepted_tokens, awarded_points, updated_at)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(rule_id) DO UPDATE SET
                remainder_tokens = excluded.remainder_tokens,
                accepted_tokens = excluded.accepted_tokens,
                awarded_points = excluded.awarded_points,
                updated_at = excluded.updated_at
            """,
            [
                .text(rule.ruleID),
                .text(location.realm.rawValue),
                .int(remainder),
                .int(totalAccepted),
                .int(totalPoints),
                .double(now.timeIntervalSince1970),
            ]
        )
        return AwardOutcome(points: points, remainderTokens: remainder, entryID: entryID)
    }

    private func bumpUsageCounter(_ name: String, by count: Int, now: Date) throws {
        try database.run(
            """
            INSERT INTO usage_counter (name, count, updated_at) VALUES (?, ?, ?)
            ON CONFLICT(name) DO UPDATE SET count = count + excluded.count,
                                           updated_at = excluded.updated_at
            """,
            [.text(name), .int(count), .double(now.timeIntervalSince1970)]
        )
    }

    public func usageCounter(_ name: String) throws -> Int {
        try database.scalarInt("SELECT count FROM usage_counter WHERE name = ?", [.text(name)]) ?? 0
    }

    private func insertUsageScanRun(_ run: UsageScanRunSummary, sourceID: String) throws {
        try database.run(
            """
            INSERT INTO usage_scan_run (
                run_id, source_id, trigger_kind, started_at, finished_at, files_considered, files_read,
                bytes_read, records_seen, inserted, duplicates, conflicts, excluded, unsupported,
                accepted_tokens, points_awarded, error_count, is_baseline, more_work
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(run.runID),
                .text(sourceID),
                .text(run.trigger),
                .double(run.startedAt.timeIntervalSince1970),
                .double(run.finishedAt.timeIntervalSince1970),
                .int(run.filesConsidered),
                .int(run.filesRead),
                .int(Int(run.bytesRead)),
                .int(run.recordsSeen),
                .int(run.inserted),
                .int(run.duplicates),
                .int(run.conflicts),
                .int(run.excluded),
                .int(run.unsupported),
                .int(run.acceptedTokens),
                .int(run.pointsAwarded),
                .int(run.errors),
                .int(run.baseline ? 1 : 0),
                .int(run.moreWork ? 1 : 0),
            ]
        )
    }

    // MARK: - Usage reads

    public func usageTotals(ruleID: String = UsageRewardRule.ompNonCacheV1.ruleID) throws -> UsageTotals {
        let state = try rewardState(ruleID: ruleID)
        let accepted = try database.scalarInt(
            "SELECT COUNT(*) FROM usage_event WHERE status = 'accepted'"
        ) ?? 0
        return UsageTotals(
            ruleID: ruleID,
            acceptedTokens: state?.acceptedTokens ?? 0,
            remainderTokens: state?.remainderTokens ?? 0,
            awardedPoints: state?.awardedPoints ?? 0,
            acceptedEvents: accepted
        )
    }

    /// Day boundary uses the given calendar; the app passes Asia/Seoul while
    /// storage stays UTC.
    public func usageDayTotals(
        day: Date,
        calendar: Calendar,
        ruleID: String = UsageRewardRule.ompNonCacheV1.ruleID
    ) throws -> UsageDayTotals {
        let interval = calendar.dateInterval(of: .day, for: day) ?? DateInterval(start: day, duration: 0)
        let start = interval.start.timeIntervalSince1970
        let end = interval.end.timeIntervalSince1970

        // "오늘 인정량" counts events by occurrence day.
        let tokens = try database.scalarInt(
            "SELECT COALESCE(SUM(e.accepted_tokens), 0) FROM usage_event e WHERE \(CreditedUsage.condition) AND e.occurred_at >= ? AND e.occurred_at < ?",
            [.double(start), .double(end)]
        ) ?? 0
        let events = try database.scalarInt(
            "SELECT COUNT(*) FROM usage_event e WHERE \(CreditedUsage.condition) AND e.occurred_at >= ? AND e.occurred_at < ?",
            [.double(start), .double(end)]
        ) ?? 0

        // "오늘 적립 포인트" counts ledger entries confirmed on the day.
        let points = try database.scalarInt(
            "SELECT COALESCE(SUM(delta_points), 0) FROM wallet_entry WHERE reason = ? AND created_at >= ? AND created_at < ?",
            [.text(WalletReason.usageReward.rawValue), .double(start), .double(end)]
        ) ?? 0

        return UsageDayTotals(acceptedTokens: tokens, acceptedEvents: events, awardedPoints: points)
    }

    /// Credited calls of the day per tool, token kinds apart (tool order).
    public func usageDayByTool(day: Date, calendar: Calendar) throws -> [UsageToolDay] {
        let interval = calendar.dateInterval(of: .day, for: day) ?? DateInterval(start: day, duration: 0)
        let rows = try database.query(
            """
            SELECT s.tool_kind, COUNT(*), SUM(e.input_tokens), SUM(e.output_tokens),
                   SUM(e.cache_read_tokens), SUM(e.cache_write_tokens), SUM(e.accepted_tokens)
            FROM usage_event e JOIN usage_source s ON s.source_id = e.source_id
            WHERE \(CreditedUsage.condition) AND e.occurred_at >= ? AND e.occurred_at < ?
            GROUP BY s.tool_kind
            """,
            [.double(interval.start.timeIntervalSince1970), .double(interval.end.timeIntervalSince1970)]
        ) { statement in
            UsageToolDay(
                tool: UsageToolKind(rawValue: statement.text(at: 0)) ?? .omp,
                events: statement.int(at: 1),
                inputTokens: statement.int(at: 2),
                outputTokens: statement.int(at: 3),
                cacheReadTokens: statement.int(at: 4),
                cacheWriteTokens: statement.int(at: 5),
                acceptedTokens: statement.int(at: 6)
            )
        }
        return rows.sorted { $0.tool.order < $1.tool.order }
    }

    public func usageDiagnostics(ruleID: String = UsageRewardRule.ompNonCacheV1.ruleID) throws -> UsageDiagnostics {
        let byStatus = try database.query(
            "SELECT status, COUNT(*) FROM usage_event GROUP BY status"
        ) { statement in
            (statement.text(at: 0), statement.int(at: 1))
        }
        func count(_ status: String) -> Int {
            byStatus.first { $0.0 == status }?.1 ?? 0
        }
        let excluded = try database.query(
            "SELECT reason, COUNT(*) FROM usage_event WHERE reason IS NOT NULL GROUP BY reason"
        ) { statement in
            (UsageRejectionReason(rawValue: statement.text(at: 0)), statement.int(at: 1))
        }
        var excludedReasons: [UsageRejectionReason: Int] = [:]
        for (reason, count) in excluded {
            guard let reason else { continue }
            excludedReasons[reason] = count
        }
        let identitylessRejects = try database.query(
            "SELECT reason, count FROM usage_reject_stat"
        ) { statement in
            (UsageRejectionReason(rawValue: statement.text(at: 0)), statement.int(at: 1))
        }
        for (reason, count) in identitylessRejects {
            guard let reason else { continue }
            excludedReasons[reason] = (excludedReasons[reason] ?? 0) + count
        }
        let checkpoints = try usageCheckpoints()
        let source = try usageSource()
        let lastRun = try database.query(
            """
            SELECT trigger_kind, started_at, finished_at, files_considered, files_read, bytes_read,
                   records_seen, inserted, duplicates, conflicts, excluded, unsupported,
                   accepted_tokens, points_awarded, error_count, is_baseline, more_work, run_id
            FROM usage_scan_run ORDER BY finished_at DESC LIMIT 1
            """
        ) { statement in
            UsageScanRunSummary(
                runID: statement.text(at: 17),
                trigger: statement.text(at: 0),
                startedAt: Date(timeIntervalSince1970: statement.double(at: 1)),
                finishedAt: Date(timeIntervalSince1970: statement.double(at: 2)),
                filesConsidered: statement.int(at: 3),
                filesRead: statement.int(at: 4),
                bytesRead: Int64(statement.int(at: 5)),
                recordsSeen: statement.int(at: 6),
                inserted: statement.int(at: 7),
                duplicates: statement.int(at: 8),
                conflicts: statement.int(at: 9),
                excluded: statement.int(at: 10),
                unsupported: statement.int(at: 11),
                acceptedTokens: statement.int(at: 12),
                pointsAwarded: statement.int(at: 13),
                errors: statement.int(at: 14),
                baseline: statement.int(at: 15) != 0,
                moreWork: statement.int(at: 16) != 0
            )
        }.first

        return UsageDiagnostics(
            lastScanAt: source?.lastScanAt,
            lastScanTrigger: lastRun?.trigger,
            lastRun: lastRun,
            acceptedEvents: count(UsageEventStatus.accepted.rawValue),
            baselineEvents: count(UsageEventStatus.baseline.rawValue),
            excludedEvents: count(UsageEventStatus.excluded.rawValue),
            unsupportedEvents: count(UsageEventStatus.unsupported.rawValue),
            conflictEvents: try usageCounter("conflict_events"),
            duplicateEvents: try usageCounter("duplicate_events"),
            excludedByIdentity: excludedReasons,
            aliasEvents: try database.scalarInt("SELECT COUNT(*) FROM usage_event_alias") ?? 0,
            sessionsObserved: try database.scalarInt("SELECT COUNT(*) FROM usage_session") ?? 0,
            sessionsWithParent: try database.scalarInt(
                "SELECT COUNT(*) FROM usage_session WHERE parent_session IS NOT NULL"
            ) ?? 0,
            filesTracked: checkpoints.count,
            filesWithErrors: checkpoints.filter { $0.status != .ok }.count,
            lastErrorReason: source?.lastReason
        )
    }

    public func usageRecentEvents(limit: Int = 20, status: UsageEventStatus? = nil) throws -> [UsageEventRecord] {
        var sql = """
            SELECT event_id, session_id, response_id, provider, model, stop_reason, occurred_at,
                   completed_at, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens,
                   accepted_tokens, status, reason, award_entry_id
            FROM usage_event
            """
        var bindings: [SQLiteValue] = []
        if let status {
            sql += " WHERE status = ?"
            bindings.append(.text(status.rawValue))
        }
        sql += " ORDER BY occurred_at DESC LIMIT ?"
        bindings.append(.int(limit))
        return try database.query(sql, bindings) { statement in
            UsageEventRecord(
                id: statement.text(at: 0),
                sessionID: statement.text(at: 1),
                responseID: statement.text(at: 2),
                provider: statement.text(at: 3),
                model: statement.text(at: 4),
                stopReason: statement.text(at: 5),
                occurredAt: Date(timeIntervalSince1970: statement.double(at: 6)),
                completedAt: statement.optionalText(at: 7).flatMap { Double($0) }.map(Date.init(timeIntervalSince1970:)),
                inputTokens: statement.int(at: 8),
                outputTokens: statement.int(at: 9),
                cacheReadTokens: statement.int(at: 10),
                cacheWriteTokens: statement.int(at: 11),
                acceptedTokens: statement.int(at: 12),
                status: UsageEventStatus(rawValue: statement.text(at: 13)) ?? .unsupported,
                reason: statement.optionalText(at: 14).flatMap(UsageRejectionReason.init(rawValue:)),
                awardEntryID: statement.optionalText(at: 15).map(WalletEntryID.init(rawValue:))
            )
        }
    }

    public func recordUsageScanTime(_ date: Date) throws {
        guard let source = try usageSource() else { return }
        try database.run(
            "UPDATE usage_source SET last_scan_at = ? WHERE source_id = ?",
            [.double(date.timeIntervalSince1970), .text(source.sourceID)]
        )
    }

    // MARK: - Coding

    static func encodeCards(_ cards: [DrawnCard]) throws -> String {
        let data = try JSONEncoder().encode(cards)
        guard let json = String(data: data, encoding: .utf8) else {
            throw PackTraceError.storage("result encoding failed")
        }
        return json
    }

    private static func decodeOpening(_ statement: SQLiteStatement) throws -> OpeningRecord {
        let json = statement.text(at: 5)
        guard let data = json.data(using: .utf8) else {
            throw PackTraceError.storage("stored opening result is not valid text")
        }
        let cards = try JSONDecoder().decode([DrawnCard].self, from: data)
        let completed = statement.optionalText(at: 3)
        return OpeningRecord(
            id: OpeningID(rawValue: statement.text(at: 0)),
            packInstanceID: PackInstanceID(rawValue: statement.text(at: 1)),
            createdAt: Date(timeIntervalSince1970: statement.double(at: 2)),
            completedAt: completed.map { Date(timeIntervalSince1970: Double($0) ?? 0) },
            revealedCount: statement.int(at: 4),
            cards: cards
        )
    }
}

#if DEBUG
public enum InjectedFailure: String, Sendable {
    case beforeExchangeCommit
    case beforeOpeningCommit
    case beforeUsageBatchCommit
}
#endif
