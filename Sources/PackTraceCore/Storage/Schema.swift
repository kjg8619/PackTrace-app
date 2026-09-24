import Foundation

enum Schema {
    static let currentVersion: Int32 = 7

    /// Brings the database up to `currentVersion`.
    ///
    /// Every step runs inside one transaction, so an interruption (a crash, a
    /// full disk, a conflicting object) leaves the file exactly as it was, at its
    /// previous version, instead of a half-created schema that no later launch
    /// could repair.
    static func migrate(_ database: SQLiteDatabase) throws {
        let observed = database.userVersion
        // Written by a newer app: running this version's code on it could lose
        // what this version does not know about, so it is not opened at all.
        guard observed <= currentVersion else {
            throw PackTraceError.newerSchema(found: Int(observed), supported: Int(currentVersion))
        }
        guard observed < currentVersion else { return }
        try database.transaction {
            // Read again under the write lock: a second process may have
            // upgraded the file between the check above and this transaction,
            // and the steps are not written to run twice.
            let startingVersion = database.userVersion
            guard startingVersion < currentVersion else { return }
            var version = startingVersion
            if version < 1 {
                try createV1(database)
                version = 1
            }
            if version < 2 {
                try createV2(database)
                version = 2
            }
            if version < 3 {
                try createV3(database)
                version = 3
            }
            if version < 4 {
                try createV4(database)
                version = 4
            }
            if version < 5 {
                try createV5(database)
                version = 5
            }
            if version < 6 {
                try createV6(database)
                version = 6
            }
            if version < 7 {
                try createV7(database)
                version = 7
            }
            try database.run("PRAGMA user_version = \(version)")
        }
    }

    /// Usage collection: source, per-file checkpoints, normalized events,
    /// reward remainder and the award ledger linkage. Additive only — existing
    /// demo collections are untouched.
    private static func createV2(_ database: SQLiteDatabase) throws {
        try database.execute("""
        CREATE TABLE usage_source (
            source_id            TEXT PRIMARY KEY,
            realm                TEXT NOT NULL,
            root_path            TEXT NOT NULL,
            connected_at         REAL NOT NULL,
            baseline_completed_at REAL,
            paused               INTEGER NOT NULL DEFAULT 0,
            last_scan_at         REAL,
            status               TEXT NOT NULL,
            last_reason          TEXT
        );

        CREATE TABLE usage_file_checkpoint (
            source_id     TEXT NOT NULL REFERENCES usage_source(source_id),
            relative_path TEXT NOT NULL,
            device_id     INTEGER NOT NULL,
            inode         INTEGER NOT NULL,
            byte_offset   INTEGER NOT NULL,
            baseline_offset INTEGER NOT NULL,
            baseline_done INTEGER NOT NULL DEFAULT 0,
            file_size     INTEGER NOT NULL,
            status        TEXT NOT NULL,
            reason        TEXT,
            updated_at    REAL NOT NULL,
            PRIMARY KEY (source_id, relative_path)
        );

        CREATE TABLE usage_event (
            event_id       TEXT PRIMARY KEY,
            source_id      TEXT NOT NULL,
            session_id     TEXT NOT NULL,
            response_id    TEXT NOT NULL,
            provider       TEXT NOT NULL,
            model          TEXT NOT NULL,
            stop_reason    TEXT NOT NULL,
            occurred_at    REAL NOT NULL,
            completed_at   REAL,
            input_tokens   INTEGER NOT NULL,
            output_tokens  INTEGER NOT NULL,
            cache_read_tokens  INTEGER NOT NULL,
            cache_write_tokens INTEGER NOT NULL,
            accepted_tokens    INTEGER NOT NULL,
            status         TEXT NOT NULL,
            reason         TEXT,
            fingerprint    TEXT NOT NULL,
            first_seen_at  REAL NOT NULL,
            award_entry_id TEXT REFERENCES wallet_entry(entry_id)
        );

        CREATE INDEX usage_event_by_occurred ON usage_event (occurred_at);
        CREATE INDEX usage_event_by_status ON usage_event (status);

        CREATE TABLE usage_counter (
            name       TEXT PRIMARY KEY,
            count      INTEGER NOT NULL,
            updated_at REAL NOT NULL
        );

        CREATE TABLE usage_reject_stat (
            reason TEXT PRIMARY KEY,
            count  INTEGER NOT NULL,
            updated_at REAL NOT NULL
        );

        CREATE TABLE usage_conflict (
            event_id        TEXT PRIMARY KEY,
            detected_at     REAL NOT NULL,
            differing_fields TEXT NOT NULL
        );

        CREATE TABLE usage_award (
            award_id       TEXT PRIMARY KEY,
            rule_id        TEXT NOT NULL,
            realm          TEXT NOT NULL,
            seq            INTEGER NOT NULL,
            accepted_tokens INTEGER NOT NULL,
            points         INTEGER NOT NULL,
            entry_id       TEXT NOT NULL REFERENCES wallet_entry(entry_id),
            created_at     REAL NOT NULL,
            UNIQUE (rule_id, realm, seq)
        );

        CREATE TABLE reward_state (
            rule_id        TEXT PRIMARY KEY,
            realm          TEXT NOT NULL,
            remainder_tokens INTEGER NOT NULL,
            accepted_tokens  INTEGER NOT NULL,
            awarded_points   INTEGER NOT NULL,
            updated_at     REAL NOT NULL
        );

        CREATE TABLE usage_scan_run (
            run_id          TEXT PRIMARY KEY,
            source_id       TEXT NOT NULL,
            trigger_kind    TEXT NOT NULL,
            started_at      REAL NOT NULL,
            finished_at     REAL NOT NULL,
            files_considered INTEGER NOT NULL,
            files_read      INTEGER NOT NULL,
            bytes_read      INTEGER NOT NULL,
            records_seen    INTEGER NOT NULL,
            inserted        INTEGER NOT NULL,
            duplicates      INTEGER NOT NULL,
            conflicts       INTEGER NOT NULL,
            excluded        INTEGER NOT NULL,
            unsupported     INTEGER NOT NULL,
            accepted_tokens INTEGER NOT NULL,
            points_awarded  INTEGER NOT NULL,
            error_count     INTEGER NOT NULL,
            is_baseline     INTEGER NOT NULL,
            more_work       INTEGER NOT NULL
        );

        CREATE INDEX usage_scan_run_by_time ON usage_scan_run (finished_at);
        """)
    }

    /// Inherited-call handling: an event id that maps to an already recorded
    /// original call, the sessions observed per source (with the fork origin
    /// when the log carries one), and a best-effort unique index that makes the
    /// provider + response id pair unique when the existing rows allow it.
    private static func createV3(_ database: SQLiteDatabase) throws {
        try database.execute("""
        CREATE TABLE usage_event_alias (
            event_id          TEXT PRIMARY KEY,
            original_event_id TEXT NOT NULL,
            reason            TEXT NOT NULL,
            session_id        TEXT NOT NULL,
            first_seen_at     REAL NOT NULL
        );

        CREATE INDEX usage_event_alias_by_original ON usage_event_alias (original_event_id);

        CREATE TABLE usage_session (
            session_id     TEXT PRIMARY KEY,
            source_id      TEXT NOT NULL,
            parent_session TEXT,
            schema_version INTEGER,
            first_seen_at  REAL NOT NULL
        );

        CREATE INDEX usage_session_by_parent ON usage_session (parent_session);
        """)

        // Enforce one reward per provider response id when the current data is
        // already clean. Older rows are never rewritten or deleted: if the
        // index cannot be created the transactional check still applies.
        let duplicates = try database.scalarInt(
            """
            SELECT COUNT(*) FROM (
                SELECT provider, response_id FROM usage_event
                GROUP BY provider, response_id HAVING COUNT(*) > 1
            )
            """
        ) ?? 0
        if duplicates == 0 {
            try database.execute(
                """
                CREATE UNIQUE INDEX IF NOT EXISTS usage_event_original_call
                ON usage_event (provider, response_id)
                """
            )
        } else {
            // Existing data already contains such a pair: keep every row and
            // fall back to the transactional check, but still index the lookup.
            try database.execute(
                """
                CREATE INDEX IF NOT EXISTS usage_event_by_original_call
                ON usage_event (provider, response_id)
                """
            )
        }
    }

    /// Random-pack pool support: which pool produced a pack, and the durable
    /// request → result mapping used for idempotent retries.
    ///
    /// `pack_instance.pool_version` stays NULL for packs received before the
    /// pool existed: their real origin is recorded as legacy rather than being
    /// presented as if they came from the three-candidate pool.
    private static func createV4(_ database: SQLiteDatabase) throws {
        let columns = try database.query("PRAGMA table_info(pack_instance)", []) { statement in
            statement.text(at: 1)
        }
        if !columns.contains("pool_version") {
            try database.execute("ALTER TABLE pack_instance ADD COLUMN pool_version TEXT")
        }
        try database.execute("""
        CREATE TABLE IF NOT EXISTS pack_request (
            request_id      TEXT PRIMARY KEY,
            realm           TEXT NOT NULL,
            pool_version    TEXT NOT NULL,
            price_points    INTEGER NOT NULL,
            economy_version INTEGER NOT NULL,
            product_id      TEXT NOT NULL,
            instance_id     TEXT NOT NULL REFERENCES pack_instance(instance_id),
            fingerprint     TEXT NOT NULL,
            created_at      REAL NOT NULL
        );

        CREATE INDEX IF NOT EXISTS pack_request_by_instance ON pack_request (instance_id);
        """)
    }

    /// Multi-tool usage.
    ///
    /// A source now records which tool it belongs to (existing rows are OMP, the
    /// only tool that could have created them). A usage event records the facts
    /// that are not OMP-specific: the reasoning subset, the normalisation rule
    /// version, and the original call key used to recognise the same real call
    /// seen from two tools. Non-file sources keep their cursor in their own
    /// table, so a database row position is never stored as a byte offset.
    private static func createV5(_ database: SQLiteDatabase) throws {
        let sourceColumns = try database.query("PRAGMA table_info(usage_source)", []) { statement in
            statement.text(at: 1)
        }
        if !sourceColumns.contains("tool_kind") {
            // Every source that exists before this migration was created by the
            // OMP adapter, so that is the only correct default.
            try database.execute("ALTER TABLE usage_source ADD COLUMN tool_kind TEXT NOT NULL DEFAULT 'omp'")
        }
        if !sourceColumns.contains("tool_version") {
            try database.execute("ALTER TABLE usage_source ADD COLUMN tool_version TEXT")
        }
        if !sourceColumns.contains("format_version") {
            try database.execute("ALTER TABLE usage_source ADD COLUMN format_version TEXT")
        }

        let eventColumns = try database.query("PRAGMA table_info(usage_event)", []) { statement in
            statement.text(at: 1)
        }
        if !eventColumns.contains("reasoning_tokens") {
            try database.execute("ALTER TABLE usage_event ADD COLUMN reasoning_tokens INTEGER")
        }
        if !eventColumns.contains("normalization_version") {
            try database.execute("ALTER TABLE usage_event ADD COLUMN normalization_version INTEGER NOT NULL DEFAULT 1")
        }
        if !eventColumns.contains("call_key") {
            try database.execute("ALTER TABLE usage_event ADD COLUMN call_key TEXT")
        }

        try database.execute("""
        CREATE INDEX IF NOT EXISTS usage_source_by_tool ON usage_source (realm, tool_kind);

        CREATE INDEX IF NOT EXISTS usage_event_by_call_key
            ON usage_event (call_key) WHERE call_key IS NOT NULL;

        CREATE TABLE IF NOT EXISTS usage_cursor (
            source_id   TEXT NOT NULL REFERENCES usage_source(source_id),
            cursor_key  TEXT NOT NULL,
            kind        TEXT NOT NULL,
            payload     TEXT NOT NULL,
            updated_at  REAL NOT NULL,
            PRIMARY KEY (source_id, cursor_key)
        );
        """)
    }

    /// Correcting a credited mistake without rewriting history.
    ///
    /// The events and the ledger entries they produced stay exactly as they were.
    /// A correction records which events were miscredited, and expresses the
    /// difference as one separate ledger entry, so the original record and the
    /// valid total can both be read afterwards. One row per incident makes
    /// re-applying the same correction a no-op.
    /// Achievements: one row per unlocked achievement, linked to the ledger
    /// entry that paid its reward. Additive only.
    private static func createV7(_ database: SQLiteDatabase) throws {
        try database.execute("""
        CREATE TABLE IF NOT EXISTS achievement (
            achievement_id  TEXT PRIMARY KEY,
            catalog_version INTEGER NOT NULL,
            achieved_at     REAL NOT NULL,
            unlocked_at     REAL NOT NULL,
            reward_points   INTEGER NOT NULL CHECK (reward_points >= 0),
            wallet_entry_id TEXT REFERENCES wallet_entry(entry_id)
        );
        """)
    }

    private static func createV6(_ database: SQLiteDatabase) throws {
        try database.execute("""
        CREATE TABLE IF NOT EXISTS usage_correction (
            incident_id            TEXT PRIMARY KEY,
            realm                  TEXT NOT NULL,
            rule_id                TEXT NOT NULL,
            excluded_tokens        INTEGER NOT NULL,
            event_count            INTEGER NOT NULL,
            event_digest           TEXT NOT NULL,
            before_accepted_tokens INTEGER NOT NULL,
            after_accepted_tokens  INTEGER NOT NULL,
            before_points          INTEGER NOT NULL,
            after_points           INTEGER NOT NULL,
            after_remainder        INTEGER NOT NULL,
            delta_points           INTEGER NOT NULL,
            entry_id               TEXT NOT NULL REFERENCES wallet_entry(entry_id),
            created_at             REAL NOT NULL
        );

        CREATE TABLE IF NOT EXISTS usage_correction_event (
            incident_id TEXT NOT NULL REFERENCES usage_correction(incident_id),
            event_id    TEXT NOT NULL,
            tokens      INTEGER NOT NULL,
            PRIMARY KEY (incident_id, event_id)
        );

        CREATE INDEX IF NOT EXISTS usage_correction_event_by_event
            ON usage_correction_event (event_id);
        """)
    }

    private static func createV1(_ database: SQLiteDatabase) throws {
        try database.execute("""
        CREATE TABLE meta (
            key   TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );

        CREATE TABLE catalog_ref (
            catalog_version TEXT PRIMARY KEY,
            content_hash    TEXT NOT NULL,
            realm           TEXT NOT NULL,
            loaded_at       REAL NOT NULL
        );

        CREATE TABLE wallet_entry (
            entry_id        TEXT PRIMARY KEY,
            idempotency_key TEXT NOT NULL UNIQUE,
            delta_points    INTEGER NOT NULL,
            reason          TEXT NOT NULL,
            ref             TEXT,
            created_at      REAL NOT NULL
        );

        CREATE TABLE pack_instance (
            instance_id     TEXT PRIMARY KEY,
            product_id      TEXT NOT NULL,
            catalog_version TEXT NOT NULL,
            recipe_version  INTEGER NOT NULL,
            acquired_at     REAL NOT NULL,
            state           TEXT NOT NULL CHECK (state IN ('sealed', 'opened')),
            exchange_entry_id TEXT NOT NULL REFERENCES wallet_entry(entry_id)
        );

        CREATE TABLE opening (
            opening_id       TEXT PRIMARY KEY,
            pack_instance_id TEXT NOT NULL UNIQUE REFERENCES pack_instance(instance_id),
            created_at       REAL NOT NULL,
            completed_at     REAL,
            revealed_count   INTEGER NOT NULL DEFAULT 0,
            result_json      TEXT NOT NULL
        );

        CREATE TABLE owned_card_instance (
            instance_id TEXT PRIMARY KEY,
            card_key    TEXT NOT NULL,
            variant     TEXT NOT NULL,
            opening_id  TEXT NOT NULL REFERENCES opening(opening_id),
            acquired_at REAL NOT NULL
        );

        CREATE INDEX owned_card_by_print ON owned_card_instance (card_key, variant);
        CREATE INDEX pack_instance_by_state ON pack_instance (state, acquired_at);
        """)
    }
}
