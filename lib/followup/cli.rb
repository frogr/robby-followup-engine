# frozen_string_literal: true

require "optparse"

module Followup
  module CLI
    DATA_DIR = File.expand_path("../../data", __dir__)

    USAGE = <<~TXT
      usage:
        followup ingest [dir]
        followup candidates --now 2026-08-13T09:00:00Z
    TXT

    def self.run(argv, out: $stdout)
      command, *args = argv
      case command
      when "ingest" then ingest(args, out)
      when "candidates" then candidates(args, out)
      else
        out.puts USAGE
        return 1
      end
      0
    rescue OptionParser::ParseError, ArgumentError => e
      out.puts "error: #{e.message}"
      1
    end

    def self.ingest(args, out)
      stats = Ingest.run(DB.open, args.first || DATA_DIR)
      stats.each { |key, value| out.puts format("%-30s %d", key.to_s.tr("_", " "), value) }
    end

    def self.candidates(args, out)
      now = parse_now(args)
      result = policy(DB.open, now)
      out.puts "candidates at #{now.iso8601}: #{result.candidates.size}"
      out.puts format("%-3s %-6s %-7s %-18s %-8s %-19s %s", "#", "score", "quote", "customer", "amount", "reason", "why")
      result.candidates.each_with_index do |c, i|
        out.puts format("%-3d %-6.1f %-7s %-18s %-8s %-19s %s", i + 1, c.score, c.quote_id,
                        c.customer_name, Followup.money(c.amount), c.reason, c.explanation)
      end
      out.puts "skipped: " + result.skipped.sort.map { |k, v| "#{k}=#{v}" }.join(" ")
    end

    def self.policy(db, now)
      Policy.run(DB.quotes(db), DB.events(db), now, sent: DB.sent_contacts(db))
    end

    # now is always an argument. The wall clock is never read.
    def self.parse_now(args)
      now = nil
      OptionParser.new { |o| o.on("--now TIME") { |v| now = v } }.parse!(args)
      raise ArgumentError, "--now is required, e.g. --now 2026-08-13T09:00:00Z" if now.nil?

      Followup.time(now) or raise ArgumentError, "--now must be ISO8601 UTC, got #{now.inspect}"
    end
  end
end
