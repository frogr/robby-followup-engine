# frozen_string_literal: true

module Followup
  class DeliveryError < StandardError; end

  # The seam a real SMS or email provider plugs into. deliver(row) returns on
  # success and raises DeliveryError on failure. A real adapter passes
  # row["idempotency_key"] to the provider as its idempotency key.
  class OutboxDeliverer
    # Nothing leaves the machine: the sent outbox row is the delivery.
    def deliver(_row); end
  end

  class FailingDeliverer
    def deliver(_row)
      raise DeliveryError, "delivery failed (forced by --fail)"
    end
  end

  module Outbox
    # The send boundary. Row status, quote still open and customer cooldown are
    # all conditions of this one statement, so there is no gap between checking
    # and sending. It deliberately has no "<= now" bound: if we know of a
    # contact or an acceptance, it blocks the send whatever now is.
    GUARDED_SEND = <<~SQL
      UPDATE outbox
         SET status = 'sent', sent_at = :now, attempts = attempts + 1, last_error = NULL
       WHERE id = :id
         AND status = :from
         AND EXISTS (SELECT 1 FROM quotes q
                      WHERE q.id = outbox.quote_id AND q.status = 'open')
         AND NOT EXISTS (SELECT 1 FROM events e
                          WHERE e.quote_id = outbox.quote_id AND e.type = 'quote_accepted')
         AND NOT EXISTS (
               SELECT 1 FROM customer_contacts c
                WHERE c.customer_phone = outbox.customer_phone
                  AND c.at > :cutoff
                  AND NOT EXISTS (SELECT 1 FROM customer_replies r
                                   WHERE r.customer_phone = c.customer_phone AND r.at > c.at))
    SQL

    # "2026-W34". Part of the idempotency key, so one quote gets at most one
    # follow-up per reason per ISO week.
    def self.iso_week(now)
      now.strftime("%G-W%V")
    end

    def self.idempotency_key(quote_id, reason, now)
      [quote_id, reason, iso_week(now)].join(":")
    end

    # Candidates -> pending rows. The UNIQUE key makes a re-run a no-op.
    def self.draft(db, candidates, now)
      created = 0
      db.transaction(:immediate) do
        candidates.each do |c|
          db.execute(<<~SQL, [c.quote_id, c.customer_phone, c.reason, c.score, Templates.render(c), idempotency_key(c.quote_id, c.reason, now), now.iso8601])
            INSERT INTO outbox (quote_id, customer_phone, reason, score, body, idempotency_key, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT (idempotency_key) DO NOTHING
          SQL
          created += db.changes
        end
      end
      { created: created, already_drafted: candidates.size - created }
    end

    # Returns the number of rows moved pending -> approved.
    def self.approve(db, id: nil)
      if id
        db.execute("UPDATE outbox SET status = 'approved' WHERE status = 'pending' AND id = ?", [id])
      else
        db.execute("UPDATE outbox SET status = 'approved' WHERE status = 'pending'")
      end
      db.changes
    end

    def self.send_approved(db, now, deliverer: OutboxDeliverer.new)
      process(db, "approved", now, deliverer)
    end

    def self.retry_failed(db, now, deliverer: OutboxDeliverer.new)
      process(db, "failed", now, deliverer)
    end

    # One row at a time, best score first, each in its own transaction, so a
    # row sent a moment ago counts against the next row for the same customer.
    def self.process(db, from, now, deliverer)
      ids = db.execute("SELECT id FROM outbox WHERE status = ? ORDER BY score DESC, id", [from]).map { |r| r["id"] }
      ids.map { |id| [id, *process_one(db, id, from, now, deliverer)] }
    end

    # -> [outcome, detail] where outcome is :sent, :failed, :blocked or :skipped.
    def self.process_one(db, id, from, now, deliverer)
      outcome = nil
      db.transaction(:immediate) do
        db.execute(GUARDED_SEND, { "id" => id, "from" => from, "now" => now.iso8601,
                                   "cutoff" => (now - Policy::COOLDOWN_DAYS * Policy::DAY).iso8601 })
        if db.changes == 1
          deliverer.deliver(db.get_first_row("SELECT * FROM outbox WHERE id = ?", [id]))
          outcome = [:sent, nil]
        else
          outcome = block(db, id, from, now)
        end
      end
      outcome
    rescue DeliveryError => e
      # The transaction rolled back, so the row never became sent.
      db.execute("UPDATE outbox SET status = 'failed' WHERE id = ? AND status = 'approved'", [id])
      db.execute("UPDATE outbox SET attempts = attempts + 1, last_error = ? WHERE id = ? AND status = 'failed'",
                 [e.message, id])
      [:failed, e.message]
    end

    def self.block(db, id, from, now)
      row = db.get_first_row("SELECT * FROM outbox WHERE id = ? AND status = ?", [id, from])
      return [:skipped, "no longer #{from}"] unless row

      reason = block_reason(db, row, now)
      db.execute("UPDATE outbox SET status = 'blocked', last_error = ? WHERE id = ?", [reason, id])
      [:blocked, reason]
    end

    def self.block_reason(db, row, now)
      status = db.get_first_value("SELECT status FROM quotes WHERE id = ?", [row["quote_id"]])
      return "quote is #{status}" unless status == "open"

      accepted = db.get_first_value("SELECT MIN(ts) FROM events WHERE quote_id = ? AND type = 'quote_accepted'",
                                    [row["quote_id"]])
      return "quote was accepted at #{accepted}" if accepted

      last = db.get_first_value("SELECT MAX(at) FROM customer_contacts WHERE customer_phone = ?",
                                [row["customer_phone"]])
      "cooldown: customer last contacted at #{last}, within #{Policy::COOLDOWN_DAYS} days of #{now.iso8601}"
    end

    def self.rows(db)
      db.execute("SELECT o.*, q.customer_name FROM outbox o JOIN quotes q ON q.id = o.quote_id ORDER BY o.id")
    end
  end
end
