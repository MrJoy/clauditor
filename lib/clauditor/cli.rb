# frozen_string_literal: true

require "optparse"

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

      if options[:anthropic] && options[:format] == "json"
        err.puts "clauditor: --anthropic is not supported with --format json (use table or csv)"
        return 1
      end

      store = options[:store] ? Store.new(roots: options[:roots], timezone: options[:timezone], dir: options[:store_dir]) : nil

      aggregator = Aggregator.new(timezone: options[:timezone], skip_through: store&.complete_through)
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

      # When a --project filter has narrowed the output to a single project the
      # project column is redundant; drop it from the human-readable views
      # (CSV/JSON keep it, and ignore the flag).
      hide_project = !options[:project].nil? && rows.map(&:project).uniq.size == 1

      if options[:anthropic]
        out.print Crosstab.for(options[:format]).render(rows, verbose: options[:verbose], hide_project: hide_project)
      else
        out.print Formatters.for(options[:format]).render(rows, hide_project: hide_project)
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

    def parse(argv, config_path: Config::DEFAULT_PATH)
      # Precedence: built-in defaults < config file < flags passed on the CLI.
      options = {
        format: "table",
        timezone: :local,
        roots: [ SessionLoader::DEFAULT_ROOT ],
        anthropic: false,
        verbose: false,
        project: nil,
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

        opts.on("--verbose", "Show full token counts (the table crosstab abbreviates them by default)") do
          options[:verbose] = true
        end

        opts.on("--project NAME", "Only include projects whose path contains NAME") do |name|
          options[:project] = name
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
