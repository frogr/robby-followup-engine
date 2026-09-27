# frozen_string_literal: true

require "json"

module Followup
  module Ingest
    # Safe to re-run: events are INSERT OR IGNORE on their dedup key and quotes
    # are upserted. A quote already closed in storage is never reopened by a
    # later snapshot.
    def self.run(db, dir)
      quotes = JSON.parse(File.read(File.join(dir, "quotes.json"))).map { |h| Quote.from(h) }
      raw, malformed = read_jsonl(File.join(dir, "events.jsonl"))
      events = Events.normalize(raw)
      inserted = store(db, quotes, events)

      { quotes: quotes.size, event_lines: raw.size + malformed, malformed: malformed,
        invalid_or_duplicate_in_file: raw.size - events.size, unique_events: events.size,
        inserted: inserted, already_stored: events.size - inserted }
    end

    # Returns how many events were new to storage.
    def self.store(db, quotes, events)
      inserted = 0
      db.transaction do
        quotes.each { |q| upsert_quote(db, q) }
        events.each do |e|
          db.execute("INSERT OR IGNORE INTO events (event_id, type, quote_id, ts, channel, direction) " \
                     "VALUES (?, ?, ?, ?, ?, ?)",
                     [e.event_id, e.type, e.quote_id, e.ts.iso8601, e.channel, e.direction])
          inserted += db.changes
        end
      end
      inserted
    end

    def self.read_jsonl(path)
      raw = []
      malformed = 0
      File.foreach(path) do |line|
        next if line.strip.empty?

        raw << JSON.parse(line)
      rescue JSON::ParserError
        malformed += 1
      end
      [raw, malformed]
    end

    def self.upsert_quote(db, quote)
      db.execute(<<~SQL, [quote.id, quote.customer_name, quote.customer_phone, quote.tech_name, quote.amount, quote.status, quote.created_at.iso8601, quote.last_contact_at&.iso8601])
        INSERT INTO quotes (id, customer_name, customer_phone, tech_name, amount, status, created_at, last_contact_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT (id) DO UPDATE SET
          customer_name = excluded.customer_name,
          customer_phone = excluded.customer_phone,
          tech_name = excluded.tech_name,
          amount = excluded.amount,
          status = CASE WHEN quotes.status IN ('accepted','dismissed') THEN quotes.status ELSE excluded.status END,
          created_at = excluded.created_at,
          last_contact_at = excluded.last_contact_at
      SQL
    end
  end
end
