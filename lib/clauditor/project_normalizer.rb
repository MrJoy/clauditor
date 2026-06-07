# frozen_string_literal: true

module Clauditor
  # Maps a session's `cwd` back to the logical repository that owns it, so that
  # git worktrees and Claude-internal directories don't show up as separate
  # projects.
  #
  # Two worktree conventions appear in real data:
  #   * `<repo>/.claude/worktrees/<name>[/...]` — Claude Code's own worktrees,
  #     alongside other internal dirs (`.claude/agents`, `.claude/hooks`).
  #     Everything under `<repo>/.claude/` collapses to `<repo>`.
  #   * `<base>/tmp/worktrees/<repo>/<name>[/...]` — externally managed
  #     worktrees that only reveal the repo *name*, not its canonical path.
  #     These yield a "loose" key (the bare repo name) that .build_remap later
  #     reattaches to the real checkout when the name is unambiguous.
  #
  # Subdirectories of a repo (e.g. `<repo>/api`, `<repo>/client/Assets/...`)
  # collapse to the repo root — see .repo_root.
  module ProjectNormalizer
    module_function

    # Resolves a path to its git repository root: the nearest ancestor
    # (inclusive) containing a `.git` entry — a directory for a normal checkout,
    # a file for a worktree. This collapses repo subdirectories onto the repo
    # itself. Returns the path unchanged when nothing is absolute or no `.git`
    # is found (e.g. the checkout no longer exists on disk). The `exist`
    # predicate is injectable for testing.
    def repo_root(path, exist: ->(candidate) { File.exist?(candidate) })
      return path unless path.start_with?("/")

      current = path
      loop do
        return current if exist.call(File.join(current, ".git"))

        parent = File.dirname(current)
        break if parent == current

        current = parent
      end
      path
    end

    # First-pass normalization of a single cwd. Returns either an absolute
    # canonical path or a "loose" bare repo name (no leading slash).
    def raw(cwd)
      path = cwd.to_s

      # Collapse Claude-internal dirs (worktrees, agents, hooks) to the repo.
      path = path.sub(%r{/\.claude/.*\z}, "")

      # Externally managed worktrees only expose the repo name.
      if (match = path.match(%r{/tmp/worktrees/([^/]+)(?:/.*)?\z}))
        return match[1]
      end

      path
    end

    # Given every raw key seen, returns a map of loose-name => canonical-path
    # for names that match exactly one canonical checkout. Ambiguous names
    # (two real repos sharing a basename) are left unmapped.
    def build_remap(raw_keys)
      by_basename = {}
      raw_keys.each do |key|
        next unless key.start_with?("/")

        basename = File.basename(key)
        if by_basename.key?(basename) && by_basename[basename] != key
          by_basename[basename] = :ambiguous
        else
          by_basename[basename] ||= key
        end
      end

      remap = {}
      raw_keys.each do |key|
        next if key.start_with?("/")

        target = by_basename[key]
        remap[key] = target if target && target != :ambiguous
      end
      remap
    end

    # Home-relative rendering for display (`/Users/me/x` => `~/x`).
    def display(project, home: Dir.home)
      if project == home
        "~"
      elsif project.start_with?("#{home}/")
        "~#{project[home.length..]}"
      else
        project
      end
    end
  end
end
