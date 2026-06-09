# frozen_string_literal: true

require "json"

module Clauditor
  # Discovers and reads Claude Code session transcripts, yielding one parsed
  # record (Hash) at a time. Malformed lines are skipped rather than fatal —
  # transcripts are append-only logs and a truncated final line is normal.
  class SessionLoader
    DEFAULT_ROOT = File.expand_path("~/.claude/projects")

    # since: skip files last modified before this Time. Record timestamps
    # never exceed the file's mtime (lines are appended as events happen), so
    # an untouched file can only contain records from days the Store already
    # covers.
    def initialize(root: DEFAULT_ROOT, since: nil)
      @root = root
      @since = since
    end

    def files
      found = Dir.glob(File.join(@root, "**", "*.jsonl"))
      return found unless @since

      found.select { |file| File.mtime(file) >= @since }
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
