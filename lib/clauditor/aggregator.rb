# frozen_string_literal: true

require "time"

module Clauditor
  # Accumulates token usage grouped by (project, day, model).
  #
  # Claude Code writes one JSONL line per content block, and every line that
  # shares a `message.id` repeats the same message-level `usage`. We therefore
  # dedupe by `message.id` globally — summing raw lines would multiply real
  # usage several-fold. Dedup is global rather than per-file because resumed
  # sessions replay earlier messages into new files.
  class Aggregator
    # One output row: usage and cost for a single (project, day, model) cell.
    Row = Struct.new(:project, :date, :model, :usage, :cost, keyword_init: true) do
      def priced?
        !cost.nil?
      end
    end

    # timezone: :local (default) buckets days in the local zone; :utc buckets
    # by the raw UTC timestamps.
    def initialize(timezone: :local)
      @timezone = timezone
      @seen_message_ids = {}
      @groups = Hash.new { |h, k| h[k] = Usage.new }
      @raw_projects = {}
    end

    # Feeds one parsed JSONL record. Ignores anything without billable usage.
    def add(record)
      return unless record["type"] == "assistant"

      message = record["message"]
      return unless message.is_a?(Hash)

      usage = message["usage"]
      message_id = message["id"]
      return unless usage.is_a?(Hash) && message_id

      return if @seen_message_ids.key?(message_id)

      @seen_message_ids[message_id] = true

      project = ProjectNormalizer.raw(record["cwd"])
      @raw_projects[project] = true
      key = [ project, day_for(record["timestamp"]), message["model"].to_s ]
      @groups[key] += Usage.from_message_usage(usage)
    end

    # Collapsed, costed rows sorted by project, then date, then model.
    def rows
      remap = ProjectNormalizer.build_remap(@raw_projects.keys)

      merged = Hash.new { |h, k| h[k] = Usage.new }
      @groups.each do |(project, date, model), usage|
        canonical = remap.fetch(project, project)
        merged[[ canonical, date, model ]] += usage
      end

      merged.map do |(project, date, model), usage|
        Row.new(
          project: project,
          date: date,
          model: model,
          usage: usage,
          cost: Pricing.cost_for(model, usage),
        )
      end.sort_by { |row| [ row.project, row.date, row.model ] }
    end

    private

    def day_for(timestamp)
      return "unknown" if timestamp.nil? || timestamp.empty?

      time = Time.parse(timestamp)
      time = @timezone == :utc ? time.utc : time.getlocal
      time.strftime("%Y-%m-%d")
    rescue ArgumentError
      "unknown"
    end
  end
end
