# frozen_string_literal: true

require "sqlite3"

module Followup
  module DB
    DEFAULT_PATH = File.expand_path("../../followup.sqlite3", __dir__)

    # Timestamps are stored as UTC ISO8601 strings ("2026-08-12T16:00:00Z"),
    # all the same width, so string comparison in SQL is time comparison.
    SCHEMA = <<~SQL
      CREATE TABLE IF NOT EXISTS quotes (
        id              TEXT PRIMARY KEY,
        customer_name   TEXT NOT NULL,
        customer_phone  TEXT NOT NULL,
        tech_name       TEXT,
        amount          INTEGER NOT NULL,
        status          TEXT NOT NULL CHECK (status IN ('open','accepted','dismissed')),
        created_at      TEXT NOT NULL,
        last_contact_at TEXT
      );
      CREATE INDEX IF NOT EXISTS quotes_phone ON quotes (customer_phone);

      -- The primary key is the dedup: ingest is INSERT OR IGNORE.
      CREATE TABLE IF NOT EXISTS events (
        event_id  TEXT PRIMARY KEY,
        type      TEXT NOT NULL,
        quote_id  TEXT NOT NULL,
        ts        TEXT NOT NULL,
        channel   TEXT,
        direction TEXT
      );
      CREATE INDEX IF NOT EXISTS events_quote_ts ON events (quote_id, ts);

      CREATE TABLE IF NOT EXISTS outbox (
        id              INTEGER PRIMARY KEY,
        quote_id        TEXT NOT NULL REFERENCES quotes (id),
        customer_phone  TEXT NOT NULL,
        reason          TEXT NOT NULL,
        score           REAL NOT NULL,
        body            TEXT NOT NULL,
        status          TEXT NOT NULL DEFAULT 'pending'
                        CHECK (status IN ('pending','approved','sent','failed','blocked')),
        idempotency_key TEXT NOT NULL UNIQUE,
        created_at      TEXT NOT NULL,
        sent_at         TEXT,
        attempts        INTEGER NOT NULL DEFAULT 0,
        last_error      TEXT
      );
      CREATE INDEX IF NOT EXISTS outbox_phone_sent ON outbox (customer_phone, sent_at);

      -- pending -> approved -> sent | failed | blocked; failed -> sent | blocked.
      -- sent and blocked are terminal. Anything else aborts the statement.
      CREATE TRIGGER IF NOT EXISTS outbox_transitions
      BEFORE UPDATE OF status ON outbox
      WHEN NOT (
        (OLD.status = 'pending'  AND NEW.status = 'approved') OR
        (OLD.status = 'approved' AND NEW.status IN ('sent','failed','blocked')) OR
        (OLD.status = 'failed'   AND NEW.status IN ('sent','blocked'))
      )
      BEGIN
        SELECT RAISE(ABORT, 'illegal outbox transition');
      END;

      CREATE TRIGGER IF NOT EXISTS outbox_no_delete
      BEFORE DELETE ON outbox
      BEGIN
        SELECT RAISE(ABORT, 'outbox rows are never deleted');
      END;
    SQL

    def self.open(path = ENV.fetch("FOLLOWUP_DB", DEFAULT_PATH))
      db = SQLite3::Database.new(path)
      db.results_as_hash = true
      db.execute("PRAGMA foreign_keys = ON")
      db.execute_batch(SCHEMA)
      db
    end

    def self.quotes(db)
      db.execute("SELECT * FROM quotes ORDER BY id").map { |row| Quote.from(row) }
    end

    # Messages this engine already sent, as [customer_phone, Time].
    def self.sent_contacts(db)
      db.execute("SELECT customer_phone, sent_at FROM outbox WHERE status = 'sent'")
        .map { |r| [r["customer_phone"], Followup.time(r["sent_at"])] }
    end

    # Always read in event-time order, never insertion order.
    def self.events(db)
      rows = db.execute("SELECT * FROM events ORDER BY ts, event_id")
      rows.map do |r|
        Event.new(event_id: r["event_id"], type: r["type"], quote_id: r["quote_id"],
                  ts: Followup.time(r["ts"]), channel: r["channel"], direction: r["direction"])
      end
    end
  end
end
