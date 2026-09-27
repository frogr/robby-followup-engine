# frozen_string_literal: true

module Followup
  Event = Struct.new(:event_id, :type, :quote_id, :ts, :channel, :direction, keyword_init: true)

  module Events
    # Raw webhook hashes -> deduped Array<Event> sorted by event time.
    # File order is never trusted. On a repeated key the first one seen wins.
    # Records missing a type, quote id or parseable timestamp are dropped.
    def self.normalize(raw)
      seen = {}
      raw.each do |hash|
        event = parse(hash) or next
        seen[event.event_id] ||= event
      end
      seen.values.sort_by { |e| [e.ts, e.event_id] }
    end

    def self.parse(hash)
      type = hash["type"]
      quote_id = hash["quote_id"]
      ts = Followup.time(hash["timestamp"] || hash["ts"])
      return nil if type.to_s.empty? || quote_id.to_s.empty? || ts.nil?

      Event.new(event_id: dedup_key(hash, type, quote_id, ts), type: type, quote_id: quote_id,
                ts: ts, channel: hash["channel"], direction: hash["direction"])
    end

    # Event id when the source gives one, otherwise the content tuple.
    def self.dedup_key(hash, type, quote_id, ts)
      id = hash["event_id"] || hash["id"]
      id.to_s.empty? ? [type, quote_id, ts.iso8601].join("|") : id.to_s
    end
  end
end
