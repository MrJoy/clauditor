# frozen_string_literal: true

require "optparse"
require "date"

module Clauditor
  # Command-line entry point: parses options, runs the aggregation, and prints
  # the requested format.
  class CLI
    FORMATS = %w[table csv json].freeze

    def self.run(argv, out: $stdout, err: $stderr, config_path: Config::DEFAULT_PATH)
      new.run(argv, out: out, err: err, config_path: config_path)
    end

    def run(argv, out: $stdout, err: $stderr, config_path: Config::DEFAULT_PATH)
      options = parse(argv, config_path: config_path)
      return 0 if options[:exit]

      validate_rollup_options!(options)

      if options[:anthropic] && options[:format] == "json"
        err.puts "clauditor: --anthropic is not supported with --format json (use table or csv)"
        return 1
      end

      store = options[:store] ? Store.new(roots: options[:roots], timezone: options[:timezone], dir: options[:store_dir]) : nil

      aggregator = Aggregator.new(timezone: options[:timezone], skip_through: store&.complete_through, remap: options[:remap])
      store&.each_row do |project, date, model, usage|
        aggregator.seed(project: project, date: date, model: model, usage: usage)
      end

      loader = SessionLoader.new(roots: options[:roots], since: store&.cutoff_time)
      loader.each_record { |record| aggregator.add(record) }

      rows = aggregator.rows
      # Persist before filtering: the dataset stays complete even when this
      # run only displays a subset.
      store&.save(rows)

      rows = filter_projects(rows, options[:project])
      rows = filter_models(rows, options[:model])
      rows = window_rows(rows, days: options[:days], since: options[:since], timezone: options[:timezone]) if options[:rollup]

      # When a --project / --model filter has narrowed the output to a single
      # project / model the corresponding column is redundant; drop it from the
      # human-readable views (CSV/JSON keep it, and ignore the flags).
      hide_project = !options[:project].nil? && rows.map(&:project).uniq.size == 1
      hide_model = !options[:model].nil? && rows.map(&:model).uniq.size == 1

      if options[:rollup]
        out.print Rollup.for(options[:format]).render(rows, verbose: options[:verbose], hide_project: hide_project, hide_model: hide_model)
      elsif options[:anthropic]
        out.print Crosstab.for(options[:format]).render(
          rows,
          verbose: options[:verbose],
          hide_project: hide_project,
          hide_model: hide_model,
          summary: options[:summary],
        )
      else
        out.print Formatters.for(options[:format]).render(rows, hide_project: hide_project, hide_model: hide_model)
      end
      0
    rescue OptionParser::ParseError, ArgumentError => e
      err.puts "clauditor: #{e.message}"
      1
    end

    private

    # Keeps rows whose project path (or its ~-relative display) contains the
    # given term, case-insensitively. Returns all rows when no term is set.
    def filter_projects(rows, term)
      return rows if term.nil?

      needle = term.downcase
      rows.select do |row|
        row.project.downcase.include?(needle) ||
          ProjectNormalizer.display(row.project).downcase.include?(needle)
      end
    end

    # Keeps rows whose model id equals the given term, case-insensitively. A
    # trailing `*` makes it a prefix match instead — `--model opus-5` matches only
    # `opus-5`, while `opus-5*` also matches `opus-5-5`. row.model is the
    # already-normalized/displayed id. Returns all rows when no term is set.
    def filter_models(rows, term)
      return rows if term.nil?

      needle = term.downcase
      if needle.end_with?("*")
        prefix = needle.delete_suffix("*")
        rows.select { |row| row.model.downcase.start_with?(prefix) }
      else
        rows.select { |row| row.model.downcase == needle }
      end
    end

    # --rollup-only flags: mutually exclusive with --anthropic and with each
    # other, and inert without --rollup (so we reject them rather than let them
    # silently do nothing).
    def validate_rollup_options!(options)
      raise ArgumentError, "--rollup and --anthropic cannot be combined" if options[:rollup] && options[:anthropic]
      raise ArgumentError, "--days and --since cannot be combined" if options[:days] && options[:since]

      unless options[:rollup]
        raise ArgumentError, "--days requires --rollup" if options[:days]
        raise ArgumentError, "--since requires --rollup" if options[:since]
        return
      end

      raise ArgumentError, "--days must be a positive integer" if options[:days] && options[:days] < 1
      validate_since!(options[:since]) if options[:since]
    end

    def validate_since!(value)
      Date.strptime(value, "%Y-%m-%d")
    rescue ArgumentError
      raise ArgumentError, "invalid --since date '#{value}' (expected YYYY-MM-DD)"
    end

    # Keeps only rows within the window. Rows dated "unknown" can't be placed on
    # the timeline, so they're dropped whenever a window is active. Date strings
    # compare lexicographically the same as chronologically.
    def window_rows(rows, days:, since:, timezone:)
      cutoff = since || days_cutoff(days, timezone)
      return rows if cutoff.nil?

      rows.select { |row| row.date != "unknown" && row.date >= cutoff }
    end

    # The inclusive lower-bound day for --days N: N calendar days back including
    # today, in the active timezone (matching how the aggregator buckets days).
    def days_cutoff(days, timezone)
      return nil if days.nil?

      today = timezone == :utc ? Time.now.utc.to_date : Date.today
      (today - (days - 1)).to_s
    end

    def parse(argv, config_path: Config::DEFAULT_PATH)
      # Precedence: built-in defaults < config file < flags passed on the CLI.
      options = {
        format: "table",
        timezone: :local,
        roots: [ SessionLoader::DEFAULT_ROOT ],
        anthropic: false,
        summary: false,
        rollup: false,
        days: nil,
        since: nil,
        verbose: false,
        project: nil,
        model: nil,
        remap: {},
        store: true,
        store_dir: Store::DEFAULT_DIR,
      }.merge(Config.load(path: config_path))

      # --root is repeatable and *replaces* config roots wholesale (flags beat
      # config); collected separately so an absent flag leaves config intact.
      cli_roots = []

      parser = OptionParser.new do |opts|
        opts.banner = "Usage: clauditor [options]"

        opts.on("-f", "--format FORMAT", FORMATS, "Output format: #{FORMATS.join(", ")} (default: table)") do |format|
          options[:format] = format
        end

        opts.on("--utc", "Bucket days by UTC instead of local time") do
          options[:timezone] = :utc
        end

        opts.on("--anthropic", "Crosstab Anthropic models across columns (table, csv; not json)") do
          options[:anthropic] = true
        end

        opts.on("--summary", "With --anthropic, merge model versions into one column per family (opus-4-8 -> opus)") do
          options[:summary] = true
        end

        opts.on("--rollup", "Collapse dates: totals per (project, model) across the window") do
          options[:rollup] = true
        end

        opts.on("--days N", Integer, "With --rollup: only the last N days, including today") do |n|
          options[:days] = n
        end

        opts.on("--since DATE", "With --rollup: only rows dated on or after DATE (YYYY-MM-DD)") do |date|
          options[:since] = date
        end

        opts.on("--verbose", "Show full token counts (the crosstab and rollup tables abbreviate them by default)") do
          options[:verbose] = true
        end

        opts.on("--project NAME", "Only include projects whose path contains NAME") do |name|
          options[:project] = name
        end

        opts.on("--model NAME", "Only include the model with id NAME (suffix with * to prefix-match)") do |name|
          options[:model] = name
        end

        opts.on("--root DIR", "Session transcripts directory; repeatable (default: ~/.claude/projects)") do |dir|
          cli_roots << File.expand_path(dir)
        end

        opts.on("--no-store", "Neither read nor update the persistent dataset") do
          options[:store] = false
        end

        opts.on("--store-dir DIR", "Persistent dataset directory (default: ~/.clauditor)") do |dir|
          options[:store_dir] = File.expand_path(dir)
        end

        opts.on("-h", "--help", "Show this help") do
          puts opts
          options[:exit] = true
        end

        opts.on("-v", "--version", "Show the version and exit") do
          puts "clauditor #{Clauditor::VERSION}"
          options[:exit] = true
        end
      end

      parser.parse(argv)
      options[:roots] = cli_roots unless cli_roots.empty?
      options
    end
  end
end
