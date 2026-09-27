# frozen_string_literal: true

require_relative "test_helper"

# Risk: a customer gets the same text twice because someone re-ran the engine
# or retried a failure.
class SendIdempotencyTest < FollowupTest
  def setup
    @db = memory_db(quotes: [quote("Q1"), quote("Q2")])
    @deliverer = RecordingDeliverer.new
  end

  def test_nothing_is_sent_without_approval
    Outbox.draft(@db, candidates(@db), NOW)

    Outbox.send_approved(@db, NOW, deliverer: @deliverer)

    assert_empty @deliverer.delivered
    assert_equal %w[pending pending], statuses(@db).map(&:last)
  end

  def test_sending_twice_delivers_once
    draft_and_approve(@db)

    first = Outbox.send_approved(@db, NOW, deliverer: @deliverer)
    second = Outbox.send_approved(@db, NOW, deliverer: @deliverer)

    assert_equal 2, first.size
    assert_empty second
    assert_equal 2, @deliverer.delivered.size
    assert_equal @deliverer.delivered.uniq, @deliverer.delivered
  end

  def test_rerunning_the_whole_pipeline_delivers_nothing_more
    2.times do
      Ingest.store(@db, DB.quotes(@db), DB.events(@db))
      draft_and_approve(@db)
      Outbox.send_approved(@db, NOW, deliverer: @deliverer)
      Outbox.retry_failed(@db, NOW, deliverer: @deliverer)
    end

    assert_equal 2, @deliverer.delivered.size
    assert_equal 2, @db.get_first_value("SELECT COUNT(*) FROM outbox")
  end

  def test_a_failed_delivery_is_recorded_as_failed_and_never_as_sent
    draft_and_approve(@db)

    Outbox.send_approved(@db, NOW, deliverer: FailingDeliverer.new)

    rows = @db.execute("SELECT status, sent_at, attempts, last_error FROM outbox")
    assert_equal [["failed", nil, 1]] * 2, rows.map { |r| r.values_at("status", "sent_at", "attempts") }
    assert_match(/delivery failed/, rows.first["last_error"])
    assert_empty DB.sent_contacts(@db)
  end

  def test_fail_then_retry_delivers_each_message_exactly_once
    draft_and_approve(@db)
    Outbox.send_approved(@db, NOW, deliverer: FailingDeliverer.new)

    Outbox.retry_failed(@db, NOW, deliverer: @deliverer)
    Outbox.retry_failed(@db, NOW, deliverer: @deliverer)
    Outbox.send_approved(@db, NOW, deliverer: @deliverer)

    assert_equal 2, @deliverer.delivered.size
    assert_equal [["sent", 2]] * 2, @db.execute("SELECT status, attempts FROM outbox").map(&:values)
  end

  def test_a_retry_that_fails_again_stays_failed_and_can_be_retried
    draft_and_approve(@db)
    2.times { Outbox.send_approved(@db, NOW, deliverer: FailingDeliverer.new) }
    Outbox.retry_failed(@db, NOW, deliverer: FailingDeliverer.new)

    assert_equal [["failed", 2]] * 2, @db.execute("SELECT status, attempts FROM outbox").map(&:values)

    Outbox.retry_failed(@db, NOW, deliverer: @deliverer)
    assert_equal 2, @deliverer.delivered.size
  end

  def test_retry_only_picks_up_failed_rows
    draft_and_approve(@db)

    Outbox.retry_failed(@db, NOW, deliverer: @deliverer)

    assert_empty @deliverer.delivered
    assert_equal %w[approved approved], statuses(@db).map(&:last)
  end

  def test_retry_runs_the_same_guardrails_as_send
    draft_and_approve(@db)
    Outbox.send_approved(@db, NOW, deliverer: FailingDeliverer.new)
    store(@db, events: [raw("quote_accepted", "Q1", NOW)])

    Outbox.retry_failed(@db, NOW, deliverer: @deliverer)

    assert_equal [%w[Q1 blocked], %w[Q2 sent]], statuses(@db)
    assert_equal 1, @deliverer.delivered.size
  end

  # A second worker holding an old id list, long after the cooldown has passed.
  def test_a_stale_worker_cannot_resend_a_sent_row
    draft_and_approve(@db)
    Outbox.send_approved(@db, NOW, deliverer: @deliverer)
    id = @db.get_first_value("SELECT id FROM outbox WHERE quote_id = 'Q1'")

    outcome = Outbox.process_one(@db, id, "approved", NOW + 5 * DAY, @deliverer)

    assert_equal :skipped, outcome.first
    assert_equal 2, @deliverer.delivered.size
    assert_equal NOW.iso8601, @db.get_first_value("SELECT sent_at FROM outbox WHERE id = ?", [id])
  end

  def test_sent_is_terminal
    draft_and_approve(@db)
    Outbox.send_approved(@db, NOW, deliverer: @deliverer)

    %w[pending approved failed blocked].each do |status|
      assert_raises(SQLite3::ConstraintException) { @db.execute("UPDATE outbox SET status = ?", [status]) }
    end
    assert_raises(SQLite3::ConstraintException) { @db.execute("DELETE FROM outbox") }
  end

  def test_a_row_cannot_skip_approval
    Outbox.draft(@db, candidates(@db), NOW)

    assert_raises(SQLite3::ConstraintException) { @db.execute("UPDATE outbox SET status = 'sent'") }
  end
end
