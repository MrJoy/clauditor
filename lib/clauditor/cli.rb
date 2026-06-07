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

      aggregator = Aggregator.new(timezone: options[:timezone])
      loader = SessionLoader.new(root: options[:root])
      loader.each_record { |record| aggregator.add(record) }

      out.print Formatters.for(options[:format]).render(aggregator.rows)
      0
    rescue OptionParser::ParseError, ArgumentError => e
      err.puts "clauditor: #{e.message}"
      1
    end

    private

    def parse(argv)
      options = { format: "table", timezone: :local, root: SessionLoader::DEFAULT_ROOT }

      parser = OptionParser.new do |opts|
        opts.banner = "Usage: clauditor [options]"

        opts.on("-f", "--format FORMAT", FORMATS, "Output format: #{FORMATS.join(", ")} (default: table)") do |format|
          options[:format] = format
        end

        opts.on("--utc", "Bucket days by UTC instead of local time") do
          options[:timezone] = :utc
        end

        opts.on("--root DIR", "Session transcripts directory (default: ~/.claude/projects)") do |dir|
          options[:root] = File.expand_path(dir)
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
