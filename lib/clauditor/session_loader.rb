# frozen_string_literal: true

require "json"

module Clauditor
  # Discovers and reads Claude Code session transcripts, yielding one parsed
  # record (Hash) at a time. Malformed lines are skipped rather than fatal —
  # transcripts are append-only logs and a truncated final line is normal.
  class SessionLoader
    DEFAULT_ROOT = File.expand_path("~/.claude/projects")

    # Expands a user-supplied root. A Claude Code config directory (~/.claude,
    # or any CLAUDE_CONFIG_DIR) holds its transcripts under projects/ next to
    # other *.jsonl files (history, jobs) that aren't sessions, so a directory
    # with a projects/ child resolves to that child. Resolving up front also
    # keeps ~/.claude and ~/.claude/projects on the same Store key.
    def self.resolve_root(dir)
      dir = File.expand_path(dir)
      projects = File.join(dir, "projects")
      File.directory?(projects) ? projects : dir
    end

    # De-duplicates a root list and drops any root nested inside another, so
    # every transcript belongs to exactly one root (and so one Store). The
    # outer root already globs into the nested one.
    def self.disjoint_roots(roots)
      roots = roots.uniq
      roots.reject do |root|
        roots.any? { |other| other != root && root.start_with?(File.join(other, "")) }
      end
    end

    # Scans one or more roots: pass a single `root:` or a `roots:` list (both
    # default to ~/.claude/projects). since: skip files last modified before
    # this Time. Record timestamps never exceed the file's mtime (lines are
    # appended as events happen), so an untouched file can only contain records
    # from days the Store already covers.
    def initialize(root: nil, roots: nil, since: nil)
      @roots = Array(roots || root || DEFAULT_ROOT)
      @since = since
    end

    # Globs every root and de-duplicates: roots may nest (a parent already
    # globs into its children), and the same file must not be read twice.
    def files
      found = @roots.flat_map { |root| Dir.glob(File.join(root, "**", "*.jsonl")) }.uniq
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
