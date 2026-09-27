# frozen_string_literal: true

require "time"

module Followup
  # Every timestamp in the system is a UTC Time in Ruby and a UTC ISO8601
  # string at rest. Returns nil for nil or unparseable input.
  def self.time(value)
    return value.utc if value.is_a?(Time)
    return nil if value.nil?

    Time.iso8601(value.to_s).utc
  rescue ArgumentError
    nil
  end
end

require_relative "followup/events"
require_relative "followup/state"
require_relative "followup/db"
require_relative "followup/ingest"
require_relative "followup/cli"
