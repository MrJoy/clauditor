# frozen_string_literal: true

require "date"
require "digest"
require "fileutils"
require "json"
require "time"

module Clauditor
  # Persists aggregated usage for completed days (default: ~/.clauditor) so
  # re-runs don't depend on transcripts that have aged out of Claude Code's
  # ~30-day retention window, and so files untouched since the covered window
  # can be skipped entirely.
  #
  # A day is complete once the clock has moved past it: every record stamped
  # before today already exists on disk at scan time, so cells for days
  # strictly before today are persisted and seeded back into the Aggregator on
  # the next run. Today's data is still accruing, so it is always recomputed
  # live and never persisted.
  #
  # Datasets are keyed by (roots, timezone) — day bucketing differs between
  # --utc and local time, and a different set of --root dirs is a different
  # dataset. The root set is sorted and de-duplicated so order and repeats
  # don't fork the key. Token counts are persisted rather than costs, so
  # pricing updates apply retroactively to historical days.
  class Store
    VERSION = 2
    DEFAULT_DIR = File.expand_path("~/.clauditor")

    DATE_PATTERN = /\A\d{4}-\d{2}-\d{2}\z/

    # Last day (inclusive, "YYYY-MM-DD") whose data is fully persisted; nil
    # for a fresh (or unreadable) store.
    attr_reader :complete_through

    # `now` is captured once at construction so a run that straddles midnight
    # never marks the day it started — only partially scanned — as complete.
    def initialize(timezone:, root: nil, roots: nil, dir: DEFAULT_DIR, now: Time.now)
      @roots = Array(roots || root).uniq.sort
      @timezone = timezone
      @dir = dir
      @today = day_of(now)
      @complete_through, @rows = load
    end

    # Files last modified before this Time can only contain records from
    # persisted days, so the loader may skip them. Nil for a fresh store.
    def cutoff_time
      return nil unless @complete_through

      day = Date.strptime(@complete_through, "%Y-%m-%d") + 1
      if @timezone == :utc
        Time.utc(day.year, day.month, day.day)
      else
        Time.new(day.year, day.month, day.day)
      end
    end

    # Yields each persisted (project, date, model, Usage) cell for seeding
    # into an Aggregator.
    def each_row
      @rows.each do |row|
        usage = Usage.new(
          input: row["input"].to_i,
          output: row["output"].to_i,
          cache_read: row["cache_read"].to_i,
          cache_write_5m: row["cache_write_5m"].to_i,
          cache_write_1h: row["cache_write_1h"].to_i,
        )
        yield row.fetch("project"), row.fetch("date"), row.fetch("model"), usage
      end
    end

    # Replaces the dataset with every completed-day cell from this run's
    # merged rows (which already include the seeded historical cells, so this
    # is a wholesale rewrite, not an append). Rows dated today or "unknown"
    # are excluded — they're recomputed live on every run.
    def save(rows)
      persistable = rows.select { |row| DATE_PATTERN.match?(row.date) && row.date < @today }

      payload = {
        version: VERSION,
        roots: @roots,
        timezone: @timezone.to_s,
        complete_through: (Date.strptime(@today, "%Y-%m-%d") - 1).strftime("%Y-%m-%d"),
        rows: persistable.map { |row| serialize(row) },
      }

      FileUtils.mkdir_p(@dir)
      tmp = "#{path}.tmp"
      File.write(tmp, JSON.pretty_generate(payload))
      File.rename(tmp, path)
    end

    def path
      key = @roots.join("\n")
      File.join(@dir, "usage-#{@timezone}-#{Digest::SHA256.hexdigest(key)[0, 12]}.json")
    end

    private

    def serialize(row)
      usage = row.usage
      {
        project: row.project,
        date: row.date,
        model: row.model,
        input: usage.input,
        output: usage.output,
        cache_read: usage.cache_read,
        cache_write_5m: usage.cache_write_5m,
        cache_write_1h: usage.cache_write_1h,
      }
    end

    def day_of(time)
      time = @timezone == :utc ? time.utc : time.getlocal
      time.strftime("%Y-%m-%d")
    end

    # Loads the dataset, treating anything unreadable or mismatched as empty —
    # the next save rebuilds it from a full scan.
    def load
      data = JSON.parse(File.read(path))
      return empty unless data.is_a?(Hash) &&
        data["version"] == VERSION &&
        data["roots"] == @roots &&
        data["timezone"] == @timezone.to_s &&
        DATE_PATTERN.match?(data["complete_through"].to_s) &&
        data["rows"].is_a?(Array)

      rows = data["rows"].select do |row|
        row.is_a?(Hash) &&
          row["project"].is_a?(String) &&
          row["model"].is_a?(String) &&
          DATE_PATTERN.match?(row["date"].to_s)
      end
      [ data["complete_through"], rows ]
    rescue Errno::ENOENT, JSON::ParserError
      empty
    end

    def empty
      [ nil, [] ]
    end
  end
end
