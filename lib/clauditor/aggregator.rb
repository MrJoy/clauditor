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
    # by the raw UTC timestamps. repo_root resolves a path to its repository
    # root (injectable for testing); results are memoized so it's not a
    # filesystem hit per record.
    def initialize(timezone: :local, repo_root: ProjectNormalizer.method(:repo_root))
      @timezone = timezone
      @repo_root = repo_root
      @repo_root_cache = {}
      @seen_message_ids = {}
      @groups = Hash.new { |h, k| h[k] = Usage.new }
      @raw_projects = {}
    end

    # Client-generated placeholder turns (API-error notices, autocompact
    # warnings) Claude Code injects into the transcript. They carry no usage and
    # aren't real model calls, so they're excluded from the report.
    SYNTHETIC_MODEL = "<synthetic>"

    # Feeds one parsed JSONL record. Ignores anything without billable usage.
    def add(record)
      return unless record["type"] == "assistant"

      message = record["message"]
      return unless message.is_a?(Hash)

      usage = message["usage"]
      message_id = message["id"]
      return unless usage.is_a?(Hash) && message_id

      model = Pricing.normalize_model(message["model"].to_s)
      return if model == SYNTHETIC_MODEL

      return if @seen_message_ids.key?(message_id)

      @seen_message_ids[message_id] = true

      raw = ProjectNormalizer.raw(record["cwd"])
      # Loose worktree names (no leading slash) are resolved later by remap;
      # absolute paths collapse to their repository root now.
      project = raw.start_with?("/") ? resolve_repo_root(raw) : raw
      @raw_projects[project] = true
      key = [ project, day_for(record["timestamp"]), model ]
      @groups[key] += Usage.from_message_usage(usage)
    end

    # Collapsed, costed rows sorted by date, then project, then model.
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
      end.sort_by { |row| [ row.date, row.project, row.model ] }
    end

    private

    def resolve_repo_root(path)
      @repo_root_cache[path] ||= @repo_root.call(path)
    end

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
