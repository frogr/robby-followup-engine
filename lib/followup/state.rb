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
  QuoteState = Struct.new(:quote, :status, :last_viewed_at, :last_replied_at,
                          :last_outbound_at, keyword_init: true) do
    def open? = status == "open"
  end

  module State
    CLOSED = %w[accepted dismissed].freeze

    # Pure: (quotes, events, now) -> Array<QuoteState>. Events after now are
    # invisible, and so are quotes created after now.
    def self.derive(quotes, events, now)
      by_quote = events.select { |e| e.ts <= now }.group_by(&:quote_id)
      quotes.select { |q| q.created_at <= now }
            .map { |q| fold(q, by_quote.fetch(q.id, []), now) }
    end

    # Either source can close a quote and nothing reopens it: a closed status in
    # quotes.json holds at every now, an accepted event holds from its timestamp.
    def self.fold(quote, events, now)
      state = QuoteState.new(quote: quote, status: CLOSED.include?(quote.status) ? quote.status : "open")
      state.last_outbound_at = quote.last_contact_at if quote.last_contact_at && quote.last_contact_at <= now

      events.each do |e|
        case e.type
        when "quote_viewed"     then state.last_viewed_at = latest(state.last_viewed_at, e.ts)
        when "customer_replied" then state.last_replied_at = latest(state.last_replied_at, e.ts)
        when "message_sent"
          state.last_outbound_at = latest(state.last_outbound_at, e.ts) unless e.direction == "inbound"
        when "quote_accepted"   then state.status = "accepted" if state.open?
        end
      end
      state
    end

    # Cooldown is per customer: phone -> latest outbound contact across all of
    # that customer's quotes, including messages this engine already sent.
    # sent is an Array of [customer_phone, Time].
    def self.last_contact_by_customer(states, sent = [])
      contacts = states.map { |s| [s.quote.customer_phone, s.last_outbound_at] } + sent
      contacts.each_with_object({}) do |(phone, at), acc|
        acc[phone] = latest(acc[phone], at) if at
      end
    end

    def self.latest(a, b)
      [a, b].compact.max
    end
  end
end
