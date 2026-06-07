# frozen_string_literal: true

require "test_helper"

module Clauditor
  class ProjectNormalizerTest < Minitest::Test
    def test_plain_repo_path_is_unchanged
      assert_equal "/Users/me/mrjoy/clauditor", ProjectNormalizer.raw("/Users/me/mrjoy/clauditor")
    end

    def test_subdirectories_are_not_merged_into_the_repo
      # Only worktrees normalize; ordinary subdirs stay distinct projects.
      assert_equal "/Users/me/games/3DTDF2P/api", ProjectNormalizer.raw("/Users/me/games/3DTDF2P/api")
    end

    def test_claude_worktree_collapses_to_repo
      assert_equal "/Users/me/games/3DTDF2P",
        ProjectNormalizer.raw("/Users/me/games/3DTDF2P/.claude/worktrees/581-enemy-definitions")
    end

    def test_nested_claude_worktree_collapses_to_outermost_repo
      cwd = "/Users/me/games/3DTDF2P/.claude/worktrees/agent-a/.claude/worktrees/agent-b"

      assert_equal "/Users/me/games/3DTDF2P", ProjectNormalizer.raw(cwd)
    end

    def test_other_claude_internal_dirs_collapse_to_repo
      assert_equal "/Users/me/games/3DTDF2P", ProjectNormalizer.raw("/Users/me/games/3DTDF2P/.claude/agents")
      assert_equal "/Users/me/games/3DTDF2P", ProjectNormalizer.raw("/Users/me/games/3DTDF2P/.claude/hooks")
    end

    def test_tmp_worktree_yields_loose_repo_name
      assert_equal "carrot", ProjectNormalizer.raw("/Users/me/tmp/worktrees/carrot/flamboyant-murdock-9a9129")
    end

    def test_build_remap_attaches_loose_name_to_unique_canonical_path
      raw_keys = [
        "/Users/me/teak/carrot",
        "carrot",
        "/Users/me/mrjoy/clauditor",
      ]

      remap = ProjectNormalizer.build_remap(raw_keys)

      assert_equal "/Users/me/teak/carrot", remap["carrot"]
    end

    def test_build_remap_leaves_ambiguous_loose_names_unmapped
      raw_keys = [
        "/Users/me/a/carrot",
        "/Users/me/b/carrot",
        "carrot",
      ]

      remap = ProjectNormalizer.build_remap(raw_keys)

      refute remap.key?("carrot")
    end

    def test_repo_root_collapses_subdirectory_to_nearest_git_ancestor
      git_dirs = [ "/Users/me/games/3DTDF2P/.git" ]
      exist = ->(candidate) { git_dirs.include?(candidate) }

      assert_equal "/Users/me/games/3DTDF2P",
        ProjectNormalizer.repo_root("/Users/me/games/3DTDF2P/client/Assets/HordesOfOrcs3", exist: exist)
    end

    def test_repo_root_returns_the_root_itself_unchanged
      exist = ->(candidate) { candidate == "/Users/me/games/3DTDF2P/.git" }

      assert_equal "/Users/me/games/3DTDF2P",
        ProjectNormalizer.repo_root("/Users/me/games/3DTDF2P", exist: exist)
    end

    def test_repo_root_stops_at_nearest_nested_repo
      # A nested checkout (its own .git) is its own root, not its parent's.
      exist = ->(candidate) { [ "/Users/me/a/.git", "/Users/me/a/b/.git" ].include?(candidate) }

      assert_equal "/Users/me/a/b", ProjectNormalizer.repo_root("/Users/me/a/b/c", exist: exist)
    end

    def test_repo_root_returns_path_unchanged_when_no_git_found
      exist = ->(_candidate) { false }

      assert_equal "/Users/me/orphan/sub", ProjectNormalizer.repo_root("/Users/me/orphan/sub", exist: exist)
    end

    def test_repo_root_ignores_non_absolute_loose_names
      assert_equal "carrot", ProjectNormalizer.repo_root("carrot", exist: ->(_c) { true })
    end

    def test_display_renders_home_relative
      assert_equal "~/teak/carrot", ProjectNormalizer.display("/home/me/teak/carrot", home: "/home/me")
      assert_equal "~", ProjectNormalizer.display("/home/me", home: "/home/me")
      assert_equal "/opt/other", ProjectNormalizer.display("/opt/other", home: "/home/me")
    end
  end
end
