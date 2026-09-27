# frozen_string_literal: true

require_relative "test_helper"

# Risk: webhooks arrive duplicated and out of order, and the quotes snapshot
# can disagree with the event stream.
class EventsStateTest < FollowupTest
  def test_a_repeated_event_id_is_stored_once
    view = raw("quote_viewed", "Q1", NOW - DAY, id: "evt-1")

    events = Events.normalize([view, view.dup, raw("quote_viewed", "Q1", NOW, id: "evt-2")])

    assert_equal %w[evt-1 evt-2], events.map(&:event_id)
  end

  def test_events_without_an_id_dedup_on_type_quote_and_timestamp
    events = Events.normalize([
      raw("quote_viewed", "Q1", NOW),
      raw("quote_viewed", "Q1", NOW),
      raw("quote_viewed", "Q2", NOW),
      raw("customer_replied", "Q1", NOW)
    ])

    assert_equal 3, events.size
  end

  def test_events_are_ordered_by_event_time_not_file_order
    events = Events.normalize([
      raw("customer_replied", "Q1", NOW - 1 * DAY, id: "c"),
      raw("quote_viewed", "Q1", NOW - 3 * DAY, id: "a"),
      raw("message_sent", "Q1", NOW - 2 * DAY, id: "b")
    ])

    assert_equal %w[a b c], events.map(&:event_id)
  end

  def test_unusable_records_are_dropped_not_fatal
    events = Events.normalize([
      { "type" => "quote_viewed", "quote_id" => "Q1", "timestamp" => "not a time" },
      { "type" => "quote_viewed", "timestamp" => NOW.iso8601 },
      raw("quote_viewed", "Q1", NOW, id: "ok")
    ])

    assert_equal %w[ok], events.map(&:event_id)
  end

  def test_ingesting_the_same_events_again_stores_nothing_new
    db = memory_db(quotes: [quote("Q1")])
    batch = [raw("quote_viewed", "Q1", NOW - DAY, id: "evt-1"), raw("customer_replied", "Q1", NOW, id: "evt-2")]

    assert_equal 2, store(db, events: batch)
    assert_equal 0, store(db, events: batch.reverse)
    assert_equal 2, DB.events(db).size
  end

  def test_seed_file_has_88_lines_and_82_distinct_events_in_time_order
    db = DB.open(":memory:")

    stats = Ingest.run(db, File.expand_path("../data", __dir__))
    events = DB.events(db)

    assert_equal [88, 82], stats.values_at(:event_lines, :unique_events)
    assert_equal events.map(&:ts).sort, events.map(&:ts)
    assert_equal 0, Ingest.run(db, File.expand_path("../data", __dir__))[:inserted]
  end

  def test_an_accepted_event_beats_an_open_status_in_the_snapshot
    quotes = [quote("Q1", status: "open")]
    events = Events.normalize([raw("quote_accepted", "Q1", NOW - DAY)])

    state = State.derive(quotes, events, NOW).first

    assert_equal "accepted", state.status
    assert_empty Policy.run(quotes, events, NOW).candidates
  end

  def test_an_accepted_event_later_than_now_has_not_happened_yet
    quotes = [quote("Q1")]
    events = Events.normalize([raw("quote_accepted", "Q1", NOW + DAY)])

    assert_equal "open", State.derive(quotes, events, NOW).first.status
    assert_equal "accepted", State.derive(quotes, events, NOW + DAY).first.status
  end

  def test_a_quote_closed_in_the_snapshot_stays_closed_with_no_event
    quotes = [quote("Q1", status: "accepted"), quote("Q2", status: "dismissed")]
    events = Events.normalize([raw("quote_viewed", "Q1", NOW - DAY), raw("customer_replied", "Q2", NOW - DAY)])

    assert_equal %w[accepted dismissed], State.derive(quotes, events, NOW).map(&:status)
    assert_empty Policy.run(quotes, events, NOW).candidates
  end

  def test_activity_after_acceptance_does_not_reopen_the_quote
    events = Events.normalize([
      raw("quote_viewed", "Q1", NOW - 1 * DAY),
      raw("quote_accepted", "Q1", NOW - 2 * DAY),
      raw("customer_replied", "Q1", NOW - 1 * DAY)
    ])

    assert_equal "accepted", State.derive([quote("Q1")], events, NOW).first.status
  end

  def test_a_later_snapshot_cannot_reopen_a_closed_quote
    db = memory_db(quotes: [quote("Q1", status: "dismissed")])

    store(db, quotes: [quote("Q1", status: "open")])

    assert_equal "dismissed", DB.quotes(db).first.status
  end

  # The reply is first in the file but last in time, so it is unanswered.
  def test_file_order_does_not_decide_whether_a_reply_was_answered
    unanswered = [raw("customer_replied", "Q1", NOW - 1 * DAY), raw("message_sent", "Q1", NOW - 5 * DAY)]
    answered   = [raw("message_sent", "Q1", NOW - 4 * DAY), raw("customer_replied", "Q1", NOW - 5 * DAY)]

    reasons = [unanswered, answered].map do |batch|
      Policy.run([quote("Q1")], Events.normalize(batch), NOW).candidates.map(&:reason)
    end

    assert_equal [["replied_unanswered"], []], reasons
  end
end
