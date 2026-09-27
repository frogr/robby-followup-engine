# frozen_string_literal: true

module Followup
  Quote = Struct.new(:id, :customer_name, :customer_phone, :tech_name, :amount, :status,
                     :created_at, :last_contact_at, keyword_init: true) do
    # Accepts a quotes.json record or a quotes table row.
    def self.from(hash)
      new(id: hash["id"], customer_name: hash["customer_name"],
          customer_phone: hash["customer_phone"], tech_name: hash["tech_name"],
          amount: hash["amount"], status: hash["status"],
          created_at: Followup.time(hash["created_at"]),
          last_contact_at: Followup.time(hash["last_contact_at"]))
    end
  end

  # A quote as of one "now": its snapshot fields plus everything folded from events.
  # followups counts message_sent events plus messages this engine sent.
  QuoteState = Struct.new(:quote, :status, :last_viewed_at, :last_replied_at,
                          :last_outbound_at, :followups, keyword_init: true) do
    def open? = status == "open"
  end

  module State
    CLOSED = %w[accepted dismissed].freeze

    # Pure: (quotes, events, now) -> Array<QuoteState>. Events after now are
    # invisible, and so are quotes created after now. sent is the messages this
    # engine already sent, as [quote_id, Time]; those always count, whatever
    # now is, because we know we sent them.
    def self.derive(quotes, events, now, sent: [])
      by_quote = events.select { |e| e.ts <= now }.group_by(&:quote_id)
      sent_by_quote = sent.group_by(&:first)
      quotes.select { |q| q.created_at <= now }.map do |q|
        state = fold(q, by_quote.fetch(q.id, []), now)
        sent_by_quote.fetch(q.id, []).each do |_, at|
          state.last_outbound_at = latest(state.last_outbound_at, at)
          state.followups += 1
        end
        state
      end
    end

    # Either source can close a quote and nothing reopens it: a closed status in
    # quotes.json holds at every now, an accepted event holds from its timestamp.
    def self.fold(quote, events, now)
      state = QuoteState.new(quote: quote, followups: 0,
                             status: CLOSED.include?(quote.status) ? quote.status : "open")
      state.last_outbound_at = quote.last_contact_at if quote.last_contact_at && quote.last_contact_at <= now

      events.each do |e|
        case e.type
        when "quote_viewed"     then state.last_viewed_at = latest(state.last_viewed_at, e.ts)
        when "customer_replied" then state.last_replied_at = latest(state.last_replied_at, e.ts)
        when "message_sent"
          next if e.direction == "inbound"

          state.last_outbound_at = latest(state.last_outbound_at, e.ts)
          state.followups += 1
        when "quote_accepted"   then state.status = "accepted" if state.open?
        end
      end
      state
    end

    # Cooldown is per customer: phone -> latest outbound contact across all of
    # that customer's quotes.
    def self.last_contact_by_customer(states)
      states.each_with_object({}) do |s, acc|
        phone = s.quote.customer_phone
        acc[phone] = latest(acc[phone], s.last_outbound_at) if s.last_outbound_at
      end
    end

    def self.latest(a, b)
      [a, b].compact.max
    end
  end
end
