# frozen_string_literal: true

require "optparse"

module Followup
  module CLI
    DATA_DIR = File.expand_path("../../data", __dir__)

    USAGE = <<~TXT
      usage:
        followup ingest [dir]
    TXT

    def self.run(argv, out: $stdout)
      command, *args = argv
      case command
      when "ingest" then ingest(args, out)
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

    # now is always an argument. The wall clock is never read.
    def self.parse_now(args)
      now = nil
      OptionParser.new { |o| o.on("--now TIME") { |v| now = v } }.parse!(args)
      raise ArgumentError, "--now is required, e.g. --now 2026-08-13T09:00:00Z" if now.nil?

      Followup.time(now) or raise ArgumentError, "--now must be ISO8601 UTC, got #{now.inspect}"
    end
  end
end
