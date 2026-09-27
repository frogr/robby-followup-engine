# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "minitest/autorun"
require "followup"

class FollowupTest < Minitest::Test
  include Followup

  NOW = Followup.time("2026-08-20T12:00:00Z")
  DAY = Policy::DAY

  # Counts what would have reached a customer. "Never double-send" is an
  # assertion about this list, not about row statuses.
  class RecordingDeliverer
    attr_reader :delivered

    def initialize = @delivered = []
    def deliver(row) = @delivered << row["idempotency_key"]
  end

  # Defaults make a plain candidate: open, 10 days old, never contacted.
  def quote(id, phone: "+1555#{id}", status: "open", amount: 1000, created_at: NOW - 10 * DAY, last_contact_at: nil)
    Quote.new(id: id, customer_name: "Pat Example", customer_phone: phone, tech_name: "Brad",
              amount: amount, status: status, created_at: created_at, last_contact_at: last_contact_at)
  end

  # A raw webhook hash, as it would appear on a line of events.jsonl.
  def raw(type, quote_id, at, id: nil)
    hash = { "type" => type, "quote_id" => quote_id, "timestamp" => at.iso8601 }
    hash["event_id"] = id if id
    hash
  end

  def store(db, quotes: [], events: [])
    Ingest.store(db, quotes, Events.normalize(events))
  end

  def memory_db(quotes: [], events: [])
    DB.open(":memory:").tap { |db| store(db, quotes: quotes, events: events) }
  end

  def candidates(db, now = NOW)
    Policy.run(DB.quotes(db), DB.events(db), now, sent: DB.sent_contacts(db)).candidates
  end

  def draft_and_approve(db, now = NOW)
    Outbox.draft(db, candidates(db, now), now)
    Outbox.approve(db)
  end

  def statuses(db)
    db.execute("SELECT quote_id, status FROM outbox ORDER BY id").map { |r| [r["quote_id"], r["status"]] }
  end
end
