# frozen_string_literal: true

module Followup
  Candidate = Struct.new(:quote_id, :customer_name, :customer_phone, :tech_name, :amount,
                         :reason, :score, :explanation, keyword_init: true)

  module Policy
    # ---- Every threshold and weight lives here -------------------------------
    DAY = 86_400
    HOUR = 3_600

    COOLDOWN_DAYS      = 3     # per customer, across all of their quotes
    MAX_AGE_DAYS       = 60    # older quotes are never candidates
    MAX_FOLLOWUPS_PER_QUOTE = 3 # message_sent events plus our own sent messages;
                                # does not apply while a customer reply is unanswered
    VIEW_WINDOW_HOURS  = 48    # a view is "recent" for this long
    BIG_AMOUNT         = 2000  # dollars
    BIG_QUIET_DAYS     = 7     # big quote with no contact for this long
    GENERIC_QUIET_DAYS = 5     # any quote with no contact for this long

    # Tiers are spaced wider than the amount bonus, so a reason always outranks
    # the one below it and amount only orders quotes within a reason.
    BASE_SCORE = {
      "replied_unanswered" => 100,
      "viewed_no_reply"    => 70,
      "big_quote_cold"     => 50,
      "generic_checkin"    => 20
    }.freeze
    AMOUNT_POINTS_PER_1000 = 1
    AMOUNT_POINTS_CAP      = 15
    # ---------------------------------------------------------------------------

    Result = Struct.new(:candidates, :skipped, keyword_init: true)

    # Pure: (quotes, events, now) plus the messages this engine already sent,
    # as [quote_id, Time] pairs. Same inputs, same output, same order.
    def self.run(quotes, events, now, sent: [])
      states = State.derive(quotes, events, now, sent: sent)
      last_contact = State.last_contact_by_customer(states)
      last_reply = last_reply_by_customer(states)
      skipped = Hash.new(0)

      candidates = states.filter_map do |state|
        phone = state.quote.customer_phone
        skip = skip_reason(state, now, last_contact[phone], last_reply[phone])
        signal = skip ? nil : signal_for(state, now)
        skip ||= "no_signal" unless signal
        next (skipped[skip] += 1) && nil if skip

        build(state, now, *signal)
      end

      Result.new(candidates: candidates.sort_by { |c| [-c.score, c.quote_id] }, skipped: skipped)
    end

    def self.skip_reason(state, now, customer_last_contact, customer_last_reply)
      return "closed" unless state.open?
      return "too_old" if now - state.quote.created_at > MAX_AGE_DAYS * DAY
      return "max follow-ups reached" if state.followups >= MAX_FOLLOWUPS_PER_QUOTE && !reply_waiting?(state)
      return "cooldown" if cooling_down?(now, customer_last_contact, customer_last_reply)

      nil
    end

    # The customer replied after our most recent contact on this quote. Answering
    # them is never capped: the cap limits chasing, not conversations.
    def self.reply_waiting?(state)
      replied = state.last_replied_at
      outbound = state.last_outbound_at
      !replied.nil? && (outbound.nil? || outbound < replied)
    end

    # A reply from the customer after our last contact lifts the cooldown: they
    # are waiting on us. Our next send becomes the new last contact.
    def self.cooling_down?(now, last_contact, last_reply)
      return false if last_contact.nil?
      return false if last_reply && last_reply > last_contact

      last_contact > now - COOLDOWN_DAYS * DAY
    end

    # First matching signal in priority order -> [reason, explanation].
    def self.signal_for(state, now)
      quote = state.quote
      replied = state.last_replied_at
      viewed = state.last_viewed_at
      outbound = state.last_outbound_at
      quiet_since = outbound || quote.created_at
      quiet_days = (now - quiet_since) / DAY

      if reply_waiting?(state)
        ["replied_unanswered", "Customer replied #{ago(now, replied)} ago and nobody has answered"]
      elsif viewed && now - viewed <= VIEW_WINDOW_HOURS * HOUR &&
            (replied.nil? || replied < viewed) && (outbound.nil? || outbound < viewed)
        ["viewed_no_reply", "Viewed the quote #{ago(now, viewed)} ago, no reply and no follow-up since"]
      elsif quote.amount >= BIG_AMOUNT && quiet_days >= BIG_QUIET_DAYS
        ["big_quote_cold", "#{Followup.money(quote.amount)} quote with no contact in #{ago(now, quiet_since)}"]
      elsif quiet_days >= GENERIC_QUIET_DAYS
        ["generic_checkin", "No contact in #{ago(now, quiet_since)}, quote is #{ago(now, quote.created_at)} old"]
      end
    end

    def self.build(state, now, reason, explanation)
      quote = state.quote
      Candidate.new(quote_id: quote.id, customer_name: quote.customer_name,
                    customer_phone: quote.customer_phone, tech_name: quote.tech_name,
                    amount: quote.amount, reason: reason, explanation: explanation,
                    score: score(reason, quote, now))
    end

    def self.score(reason, quote, now)
      bonus = [quote.amount / 1000.0 * AMOUNT_POINTS_PER_1000, AMOUNT_POINTS_CAP].min
      total = BASE_SCORE.fetch(reason) + bonus
      total *= age_decay(quote, now) if reason == "generic_checkin"
      total.round(1)
    end

    # Linear from 1.0 at creation to 0.0 at MAX_AGE_DAYS.
    def self.age_decay(quote, now)
      age_days = (now - quote.created_at) / DAY
      [1.0 - age_days / MAX_AGE_DAYS, 0.0].max
    end

    def self.last_reply_by_customer(states)
      states.each_with_object({}) do |s, acc|
        phone = s.quote.customer_phone
        acc[phone] = State.latest(acc[phone], s.last_replied_at) if s.last_replied_at
      end
    end

    def self.ago(now, time)
      seconds = now - time
      seconds < 2 * DAY ? "#{(seconds / HOUR).round}h" : "#{(seconds / DAY).round(1)} days"
    end
  end
end
