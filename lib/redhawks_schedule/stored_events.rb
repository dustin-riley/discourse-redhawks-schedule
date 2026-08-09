# frozen_string_literal: true

require "time"

module RedhawksSchedule
  # PluginStore round-trips through JSON, so stored events come back with
  # string keys and times as strings, while the planner and composer expect
  # symbol keys and real Times. Pure, and shared: a second copy of this in
  # the controller would drift from the job's copy one field at a time.
  module StoredEvents
    module_function

    def deserialize(payload)
      return [] if payload.nil?

      (payload["events"] || payload[:events] || []).map { |row| revive(row) }
    end

    def revive(row)
      event = {}
      row.each { |key, value| event[key.to_sym] = value }

      event[:start_utc] = Time.iso8601(event[:start_utc]) if event[:start_utc].is_a?(String)
      event[:end_utc] = Time.iso8601(event[:end_utc]) if event[:end_utc].is_a?(String)

      broadcast = {}
      (event[:broadcast] || {}).each { |key, value| broadcast[key.to_sym] = value }
      event[:broadcast] = broadcast

      event
    end
  end
end
