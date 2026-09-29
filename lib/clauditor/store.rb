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
  # Datasets are keyed by (root, timezone) — day bucketing differs between
  # --utc and local time. Each root keeps its own dataset, so adding or
  # dropping a --root never hides another root's history: a run opens one
  # Store per root it scans, and a root left out keeps its file for when it
  # returns. Token counts are persisted rather than costs, so pricing updates
  # apply retroactively to historical days.
  class Store
    VERSION = 2
    DEFAULT_DIR = File.expand_path("~/.clauditor")

    DATE_PATTERN = /\A\d{4}-\d{2}-\d{2}\z/

    # A dataset written under a key that no longer names a single root: a
    # 0.0.2/0.0.3 root-set dataset, or a one-root dataset whose root now
    # resolves elsewhere (e.g. ~/.claude before config dirs resolved to
    # projects/). Its rows can't be split per root, so it is never rewritten;
    # whenever a run includes all of `roots` (resolved), the Aggregator
    # reconciles it cell by cell with those roots' own data.
    Archive = Struct.new(:path, :roots, :complete_through, :rows, keyword_init: true) do
      def each_row(&block)
        Store.each_cell(rows, &block)
      end
    end

    # Every archive in `dir` for `timezone`.
    def self.archives(timezone:, dir: DEFAULT_DIR)
      Dir.glob(File.join(dir, "usage-#{timezone}-*.json")).sort.filter_map do |path|
        data = read(path, timezone)
        next unless data

        roots = data["roots"]
        next if roots.size == 1 && SessionLoader.resolve_root(roots.first) == roots.first

        Archive.new(
          path: path,
          roots: roots.map { |root| SessionLoader.resolve_root(root) }.uniq.sort,
          complete_through: data["complete_through"],
          rows: data["rows"],
        )
      end
    end

    # Parses a dataset file, or nil when it's unreadable, from another version
    # or timezone, or malformed. Malformed rows are dropped.
    def self.read(path, timezone)
      data = JSON.parse(File.read(path))
      return nil unless data.is_a?(Hash) &&
        data["version"] == VERSION &&
        data["roots"].is_a?(Array) && !data["roots"].empty? && data["roots"].all?(String) &&
        data["timezone"] == timezone.to_s &&
        DATE_PATTERN.match?(data["complete_through"].to_s) &&
        data["rows"].is_a?(Array)

      rows = data["rows"].select do |row|
        row.is_a?(Hash) &&
          row["project"].is_a?(String) &&
          row["model"].is_a?(String) &&
          DATE_PATTERN.match?(row["date"].to_s)
      end
      data.merge("rows" => rows)
    rescue Errno::ENOENT, JSON::ParserError
      nil
    end

    # Yields (project, date, model, Usage) for each persisted row.
    def self.each_cell(rows)
      rows.each do |row|
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

    # Last day (inclusive, "YYYY-MM-DD") whose data is fully persisted; nil
    # for a fresh (or unreadable) store.
    attr_reader :complete_through

    # `now` is captured once at construction so a run that straddles midnight
    # never marks the day it started — only partially scanned — as complete.
    def initialize(root:, timezone:, dir: DEFAULT_DIR, now: Time.now)
      @root = root
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
    def each_row(&block)
      Store.each_cell(@rows, &block)
    end

    # Replaces the dataset with every completed-day cell from this run's
    # merged rows (which already include the seeded historical cells, so this
    # is a wholesale rewrite, not an append). Rows dated today or "unknown"
    # are excluded — they're recomputed live on every run.
    def save(rows)
      persistable = rows.select { |row| DATE_PATTERN.match?(row.date) && row.date < @today }

      payload = {
        version: VERSION,
        roots: [ @root ],
        timezone: @timezone.to_s,
        complete_through: (Date.strptime(@today, "%Y-%m-%d") - 1).strftime("%Y-%m-%d"),
        rows: persistable.map { |row| serialize(row) },
      }

      FileUtils.mkdir_p(@dir)
      tmp = "#{path}.tmp"
      File.write(tmp, JSON.pretty_generate(payload))
      File.rename(tmp, path)
    end

    # The key hashes the root the same way the old root-set key hashed a
    # one-root set, so datasets written before per-root storage still load.
    def path
      key = @root
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
      data = Store.read(path, @timezone)
      return [ nil, [] ] unless data && data["roots"] == [ @root ]

      [ data["complete_through"], data["rows"] ]
    end
  end
end
