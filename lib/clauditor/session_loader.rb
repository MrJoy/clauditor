# frozen_string_literal: true

require "json"

module Clauditor
  # Discovers and reads Claude Code session transcripts, yielding one parsed
  # record (Hash) at a time. Malformed lines are skipped rather than fatal —
  # transcripts are append-only logs and a truncated final line is normal.
  class SessionLoader
    DEFAULT_ROOT = File.expand_path("~/.claude/projects")

    def initialize(root: DEFAULT_ROOT)
      @root = root
    end

    def files
      Dir.glob(File.join(@root, "**", "*.jsonl"))
    end

    # Yields each parsed record across every transcript file.
    def each_record
      return enum_for(:each_record) unless block_given?

      files.each do |file|
        File.foreach(file) do |line|
          line = line.strip
          next if line.empty?

          record =
            begin
              JSON.parse(line)
            rescue JSON::ParserError
              nil
            end
          yield record if record
        end
      end
    end
  end
end
