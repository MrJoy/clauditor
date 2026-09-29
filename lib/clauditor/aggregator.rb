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
    # filesystem hit per record. skip_through drops records dated on or before
    # the given "YYYY-MM-DD" day — those days come pre-aggregated from the
    # Store via #seed, and counting them again (e.g. a resumed session
    # replaying old messages into a new file) would double them. Each root has
    # its own Store, so skip_through may also be a { root => day } hash; a
    # root missing from it has nothing covered.
    # remap is a user-supplied { project => project } hash (from the config
    # file) applied last, after the automatic worktree reattachment, to fold
    # stray project keys (typically long-gone worktrees) onto a canonical one.
    # archived maps a root to the key of the Store archive covering it (the
    # archive's cells are seeded with that key as their root). An archive and
    # its roots' own cells each undercount the same usage — each may have lost
    # transcripts the other kept — so the merged rows take the larger of the
    # two per cell rather than their sum. rows(root:) is unaffected.
    def initialize(timezone: :local, repo_root: ProjectNormalizer.method(:repo_root), skip_through: nil, remap: {}, archived: {})
      @timezone = timezone
      @repo_root = repo_root
      @skip_through = skip_through.is_a?(Hash) ? skip_through : Hash.new(skip_through)
      @remap = remap
      @archived = archived
      @archive_keys = archived.values.to_h { |key| [ key, true ] }
      @repo_root_cache = {}
      @seen_message_ids = {}
      @groups = Hash.new { |h, k| h[k] = Usage.new }
      @raw_projects = {}
    end

    # Client-generated placeholder turns (API-error notices, autocompact
    # warnings) Claude Code injects into the transcript. They carry no usage and
    # aren't real model calls, so they're excluded from the report.
    SYNTHETIC_MODEL = "<synthetic>"

    # Feeds one parsed JSONL record, read from `root`. Ignores anything without
    # billable usage.
    def add(record, root: nil)
      return unless record["type"] == "assistant"

      message = record["message"]
      return unless message.is_a?(Hash)

      usage = message["usage"]
      message_id = message["id"]
      return unless usage.is_a?(Hash) && message_id

      model = Pricing.normalize_model(message["model"].to_s)
      return if model == SYNTHETIC_MODEL

      day = day_for(record["timestamp"])
      return if covered?(root, day)

      return if @seen_message_ids.key?(message_id)

      @seen_message_ids[message_id] = true

      raw = ProjectNormalizer.raw(record["cwd"])
      # Loose worktree names (no leading slash) are resolved later by remap;
      # absolute paths collapse to their repository root now.
      project = raw.start_with?("/") ? resolve_repo_root(raw) : raw
      @raw_projects[project] = true
      @groups[[ root, project, day, model ]] += Usage.from_message_usage(usage)
    end

    # Injects an already-aggregated cell (from Store). Bypasses dedup and cwd
    # normalization — the project key is already canonical — but registers the
    # project so loose worktree names can still reattach across runs, in
    # either direction, via remap.
    def seed(project:, date:, model:, usage:, root: nil)
      @raw_projects[project] = true
      @groups[[ root, project, date, model ]] += usage
    end

    # Collapsed, costed rows sorted by date, then project, then model. Merges
    # every root unless `root:` asks for that root's cells alone (what its
    # Store persists). Worktree reattachment still sees every root's projects.
    def rows(root: :all)
      remap = ProjectNormalizer.build_remap(@raw_projects.keys)

      merged = Hash.new { |h, k| h[k] = Usage.new }
      # archive key => { archive: cells, roots: cells }, for the per-cell max.
      sides = Hash.new { |h, k| h[k] = Hash.new { |hh, kk| hh[kk] = Hash.new { |c, ck| c[ck] = Usage.new } } }
      @groups.each do |(cell_root, project, date, model), usage|
        next unless root == :all || root == cell_root

        canonical = remap.fetch(project, project)
        canonical = @remap.fetch(canonical, canonical)
        cell = [ canonical, date, model ]
        if root != :all
          merged[cell] += usage
        elsif @archive_keys.key?(cell_root)
          sides[cell_root][:archive][cell] += usage
        elsif (key = @archived[cell_root])
          sides[key][:roots][cell] += usage
        else
          merged[cell] += usage
        end
      end
      sides.each_value do |side|
        (side[:archive].keys | side[:roots].keys).each do |cell|
          merged[cell] += side[:archive][cell].max(side[:roots][cell])
        end
      end

      merged.map do |(project, date, model), usage|
        Row.new(
          project: project,
          date: date,
          model: model,
          usage: usage,
          cost: Pricing.cost_for(model, usage, date),
        )
      end.sort_by { |row| [ row.date, row.project, row.model ] }
    end

    private

    # "unknown" days are never considered covered: they can't be proven
    # complete, so they're recomputed live (and never persisted) every run.
    def covered?(root, day)
      limit = @skip_through[root]
      limit && day != "unknown" && day <= limit
    end

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
