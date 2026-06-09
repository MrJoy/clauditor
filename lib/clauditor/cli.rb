# frozen_string_literal: true

require "optparse"

module Clauditor
  # Command-line entry point: parses options, runs the aggregation, and prints
  # the requested format.
  class CLI
    FORMATS = %w[table csv json].freeze

    def self.run(argv, out: $stdout, err: $stderr)
      new.run(argv, out: out, err: err)
    end

    def run(argv, out: $stdout, err: $stderr)
      options = parse(argv)
      return 0 if options[:exit]

      if options[:anthropic] && options[:format] == "json"
        err.puts "clauditor: --anthropic is not supported with --format json (use table or csv)"
        return 1
      end

      store = options[:store] ? Store.new(root: options[:root], timezone: options[:timezone], dir: options[:store_dir]) : nil

      aggregator = Aggregator.new(timezone: options[:timezone], skip_through: store&.complete_through)
      store&.each_row do |project, date, model, usage|
        aggregator.seed(project: project, date: date, model: model, usage: usage)
      end

      loader = SessionLoader.new(root: options[:root], since: store&.cutoff_time)
      loader.each_record { |record| aggregator.add(record) }

      rows = aggregator.rows
      # Persist before filtering: the dataset stays complete even when this
      # run only displays a subset.
      store&.save(rows)

      rows = filter_projects(rows, options[:project])

      if options[:anthropic]
        out.print Crosstab.for(options[:format]).render(rows, verbose: options[:verbose])
      else
        out.print Formatters.for(options[:format]).render(rows)
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

    def parse(argv)
      options = {
        format: "table",
        timezone: :local,
        root: SessionLoader::DEFAULT_ROOT,
        anthropic: false,
        verbose: false,
        project: nil,
        store: true,
        store_dir: Store::DEFAULT_DIR,
      }

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

        opts.on("--root DIR", "Session transcripts directory (default: ~/.claude/projects)") do |dir|
          options[:root] = File.expand_path(dir)
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
      end

      parser.parse(argv)
      options
    end
  end
end
