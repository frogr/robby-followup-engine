# frozen_string_literal: true

require "optparse"

module Followup
  module CLI
    DATA_DIR = File.expand_path("../../data", __dir__)

    USAGE = <<~TXT
      usage:
        followup ingest [dir]
        followup candidates --now 2026-08-13T09:00:00Z
        followup draft --now TIME
        followup approve <id> | --all
        followup send --now TIME [--fail]
        followup retry --now TIME
        followup outbox
    TXT

    def self.run(argv, out: $stdout)
      command, *args = argv
      case command
      when "ingest"     then ingest(args, out)
      when "candidates" then candidates(args, out)
      when "draft"      then draft(args, out)
      when "approve"    then approve(args, out)
      when "send"       then send_approved(args, out)
      when "retry"      then retry_failed(args, out)
      when "outbox"     then outbox(out)
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
      now = parse_options(args)[:now]
      result = policy(DB.open, now)
      out.puts "candidates at #{now.iso8601}: #{result.candidates.size}"
      out.puts format("%-3s %-6s %-7s %-18s %-8s %-19s %s", "#", "score", "quote", "customer", "amount", "reason", "why")
      result.candidates.each_with_index do |c, i|
        out.puts format("%-3d %-6.1f %-7s %-18s %-8s %-19s %s", i + 1, c.score, c.quote_id,
                        c.customer_name, Followup.money(c.amount), c.reason, c.explanation)
      end
      out.puts "skipped: " + result.skipped.sort.map { |k, v| "#{k}=#{v}" }.join(" ")
    end

    def self.draft(args, out)
      now = parse_options(args)[:now]
      db = DB.open
      stats = Outbox.draft(db, policy(db, now).candidates, now)
      out.puts "draft at #{now.iso8601} (#{Outbox.iso_week(now)}): " \
               "#{stats[:created]} created, #{stats[:already_drafted]} already drafted"
    end

    def self.approve(args, out)
      all = args.delete("--all")
      id = args.first
      raise ArgumentError, "approve needs an outbox id or --all" unless all || id&.match?(/\A\d+\z/)

      count = Outbox.approve(DB.open, id: all ? nil : id.to_i)
      out.puts "approved #{count}"
    end

    def self.send_approved(args, out)
      options = parse_options(args)
      deliverer = options[:fail] ? FailingDeliverer.new : OutboxDeliverer.new
      report(out, "send", options[:now], Outbox.send_approved(DB.open, options[:now], deliverer: deliverer))
    end

    def self.retry_failed(args, out)
      now = parse_options(args)[:now]
      report(out, "retry", now, Outbox.retry_failed(DB.open, now))
    end

    def self.report(out, verb, now, results)
      counts = results.map { |_, outcome, _| outcome }.tally
      summary = %i[sent failed blocked skipped].map { |k| "#{counts.fetch(k, 0)} #{k}" }.join(", ")
      out.puts "#{verb} at #{now.iso8601}: #{results.size} processed, #{summary}"
      results.each do |id, outcome, detail|
        out.puts "  ##{id} #{outcome}: #{detail}" unless outcome == :sent
      end
    end

    def self.outbox(out)
      rows = Outbox.rows(DB.open)
      out.puts "outbox: #{rows.size} rows  " + rows.map { |r| r["status"] }.tally.sort.map { |k, v| "#{k}=#{v}" }.join(" ")
      rows.each do |r|
        out.puts format("#%-3d %-8s %-6.1f %-7s %-16s %-19s tries=%d sent_at=%s", r["id"], r["status"], r["score"],
                        r["quote_id"], r["customer_name"], r["reason"], r["attempts"], r["sent_at"] || "-")
        out.puts "       key: #{r["idempotency_key"]}"
        out.puts "       msg: #{r["body"]}"
        out.puts "       err: #{r["last_error"]}" if r["last_error"]
      end
    end

    def self.policy(db, now)
      Policy.run(DB.quotes(db), DB.events(db), now, sent: DB.sent_contacts(db))
    end

    # now is always an argument. The wall clock is never read.
    def self.parse_options(args)
      options = {}
      OptionParser.new do |o|
        o.on("--now TIME") { |v| options[:now] = v }
        o.on("--fail") { options[:fail] = true }
      end.parse!(args)
      raise ArgumentError, "--now is required, e.g. --now 2026-08-13T09:00:00Z" if options[:now].nil?

      now = options[:now]
      options[:now] = Followup.time(now) or raise ArgumentError, "--now must be ISO8601 UTC, got #{now.inspect}"
      options
    end
  end
end
