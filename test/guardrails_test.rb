# frozen_string_literal: true

require_relative "test_helper"

# Risk: the world changes between draft and send. Each guardrail is tested at
# the send boundary with a row that was legitimately drafted and approved.
class GuardrailsTest < FollowupTest
  KAREN = "+19175552003"

  # ---- cooldown, per customer ------------------------------------------------

  def test_two_quotes_for_one_customer_send_one_and_block_the_other
    db = memory_db(quotes: [quote("Q1", phone: KAREN, amount: 500), quote("Q2", phone: KAREN, amount: 900)])
    draft_and_approve(db)
    deliverer = RecordingDeliverer.new

    Outbox.send_approved(db, NOW, deliverer: deliverer)

    assert_equal [%w[Q2 sent], %w[Q1 blocked]], statuses(db).sort_by(&:last).reverse
    assert_equal 1, deliverer.delivered.size
    assert_match(/cooldown/, db.get_first_value("SELECT last_error FROM outbox WHERE quote_id = 'Q1'"))
  end

  def test_a_message_sent_event_that_lands_after_approval_blocks_the_send
    db = memory_db(quotes: [quote("Q1", phone: KAREN), quote("Q2", phone: KAREN, created_at: NOW - DAY)])
    draft_and_approve(db)
    store(db, events: [raw("message_sent", "Q2", NOW - DAY)])
    deliverer = RecordingDeliverer.new

    Outbox.send_approved(db, NOW, deliverer: deliverer)

    assert_equal [%w[Q1 blocked]], statuses(db)
    assert_empty deliverer.delivered
  end

  def test_policy_skips_a_customer_contacted_on_another_quote
    quotes = [quote("Q1", phone: KAREN), quote("Q2", phone: KAREN, last_contact_at: NOW - DAY)]

    result = Policy.run(quotes, [], NOW)

    assert_empty result.candidates
    assert_equal 2, result.skipped["cooldown"]
  end

  def test_cooldown_ends_exactly_three_days_after_the_last_contact
    inside = memory_db(quotes: [quote("Q1", last_contact_at: NOW - 10 * DAY)])
    edge   = memory_db(quotes: [quote("Q1", last_contact_at: NOW - 10 * DAY)])
    [inside, edge].each { |db| draft_and_approve(db) }
    store(inside, events: [raw("message_sent", "Q1", NOW - 3 * DAY + 1)])
    store(edge,   events: [raw("message_sent", "Q1", NOW - 3 * DAY)])

    [inside, edge].each { |db| Outbox.send_approved(db, NOW) }

    assert_equal [%w[Q1 blocked]], statuses(inside)
    assert_equal [%w[Q1 sent]], statuses(edge)
  end

  def test_a_customer_reply_after_our_last_contact_lifts_the_cooldown
    db = memory_db(quotes: [quote("Q1")],
                   events: [raw("message_sent", "Q1", NOW - DAY), raw("customer_replied", "Q1", NOW - DAY / 2)])

    assert_equal ["replied_unanswered"], candidates(db).map(&:reason)
    draft_and_approve(db)
    Outbox.send_approved(db, NOW)

    assert_equal [%w[Q1 sent]], statuses(db)
  end

  def test_our_own_send_restarts_the_cooldown_even_after_a_reply
    db = memory_db(quotes: [quote("Q1")], events: [raw("customer_replied", "Q1", NOW - DAY)])
    draft_and_approve(db)
    Outbox.send_approved(db, NOW)

    assert_empty candidates(db, NOW + DAY)
    assert_equal ["generic_checkin"], candidates(db, NOW + 5 * DAY).map(&:reason)
  end

  # ---- never message a closed quote -------------------------------------------

  def test_a_quote_accepted_after_approval_is_blocked
    db = memory_db(quotes: [quote("Q1")])
    draft_and_approve(db)
    store(db, events: [raw("quote_accepted", "Q1", NOW - 1)])
    deliverer = RecordingDeliverer.new

    Outbox.send_approved(db, NOW, deliverer: deliverer)

    assert_equal [%w[Q1 blocked]], statuses(db)
    assert_empty deliverer.delivered
    assert_match(/accepted/, db.get_first_value("SELECT last_error FROM outbox"))
  end

  def test_a_quote_dismissed_in_a_newer_snapshot_is_blocked
    db = memory_db(quotes: [quote("Q1")])
    draft_and_approve(db)
    store(db, quotes: [quote("Q1", status: "dismissed")])
    deliverer = RecordingDeliverer.new

    Outbox.send_approved(db, NOW, deliverer: deliverer)

    assert_equal [%w[Q1 blocked]], statuses(db)
    assert_empty deliverer.delivered
  end

  def test_blocked_is_terminal_and_retry_does_not_touch_it
    db = memory_db(quotes: [quote("Q1")])
    draft_and_approve(db)
    store(db, events: [raw("quote_accepted", "Q1", NOW - 1)])
    Outbox.send_approved(db, NOW)

    assert_empty Outbox.retry_failed(db, NOW)
    assert_empty Outbox.send_approved(db, NOW)
    assert_raises(SQLite3::ConstraintException) { db.execute("UPDATE outbox SET status = 'approved'") }
  end

  # ---- per-quote cap -----------------------------------------------------------

  def test_a_quote_with_three_follow_ups_is_never_a_candidate_again
    texts = [20, 15, 10].map { |days| raw("message_sent", "Q1", NOW - days * DAY) }
    db = memory_db(quotes: [quote("Q1", created_at: NOW - 30 * DAY), quote("Q2", created_at: NOW - 30 * DAY)],
                   events: texts + texts.first(2).map { |e| e.merge("quote_id" => "Q2") })

    result = Policy.run(DB.quotes(db), DB.events(db), NOW, sent: DB.sent_contacts(db))
    assert_equal %w[Q2], result.candidates.map(&:quote_id)
    assert_equal({ "max follow-ups reached" => 1 }, result.skipped)

    # Q2 has two events; our own send is its third.
    draft_and_approve(db)
    Outbox.send_approved(db, NOW)
    later = Policy.run(DB.quotes(db), DB.events(db), NOW + 10 * DAY, sent: DB.sent_contacts(db))

    assert_empty later.candidates
    assert_equal({ "max follow-ups reached" => 2 }, later.skipped)
  end

  # ---- never draft the same follow-up twice ------------------------------------

  def test_drafting_again_in_the_same_week_creates_nothing
    db = memory_db(quotes: [quote("Q1"), quote("Q2")])

    first = Outbox.draft(db, candidates(db), NOW)
    again = Outbox.draft(db, candidates(db), NOW + DAY)

    assert_equal({ created: 2, already_drafted: 0 }, first)
    assert_equal({ created: 0, already_drafted: 2 }, again)
    assert_equal Outbox.iso_week(NOW), Outbox.iso_week(NOW + DAY)
  end

  def test_the_database_itself_rejects_a_duplicate_idempotency_key
    db = memory_db(quotes: [quote("Q1")])
    Outbox.draft(db, candidates(db), NOW)
    insert = "INSERT INTO outbox (quote_id, customer_phone, reason, score, body, idempotency_key, created_at) " \
             "SELECT quote_id, customer_phone, reason, score, body, idempotency_key, created_at FROM outbox"

    assert_raises(SQLite3::ConstraintException) { db.execute(insert) }
  end

  def test_the_same_reason_in_a_later_iso_week_is_a_new_follow_up
    db = memory_db(quotes: [quote("Q1")])
    draft_and_approve(db)
    Outbox.send_approved(db, NOW)

    next_week = NOW + 7 * DAY
    Outbox.draft(db, candidates(db, next_week), next_week)

    keys = db.execute("SELECT idempotency_key FROM outbox ORDER BY id").map { |r| r["idempotency_key"] }
    assert_equal ["Q1:generic_checkin:2026-W34", "Q1:generic_checkin:2026-W35"], keys
  end
end
