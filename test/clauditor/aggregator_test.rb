# frozen_string_literal: true

require "test_helper"

module Clauditor
  class AggregatorTest < Minitest::Test
    def assistant(id:, cwd:, model: "claude-opus-4-8", timestamp: "2026-06-07T21:05:17.266Z", usage: default_usage)
      {
        "type" => "assistant",
        "cwd" => cwd,
        "timestamp" => timestamp,
        "message" => { "id" => id, "model" => model, "usage" => usage },
      }
    end

    def default_usage
      {
        "input_tokens" => 100,
        "output_tokens" => 10,
        "cache_read_input_tokens" => 1000,
        "cache_creation" => { "ephemeral_5m_input_tokens" => 50, "ephemeral_1h_input_tokens" => 0 },
      }
    end

    def test_dedupes_repeated_message_ids
      agg = Aggregator.new(timezone: :utc)
      # Same message id repeated three times (one JSONL line per content block).
      3.times { agg.add(assistant(id: "msg_1", cwd: "/Users/me/proj")) }

      rows = agg.rows

      assert_equal 1, rows.size
      assert_equal 100, rows.first.usage.input
      assert_equal 10, rows.first.usage.output
    end

    def test_groups_by_project_day_and_model
      agg = Aggregator.new(timezone: :utc)
      agg.add(assistant(id: "a", cwd: "/Users/me/proj", model: "claude-opus-4-8"))
      agg.add(assistant(id: "b", cwd: "/Users/me/proj", model: "claude-sonnet-4-6"))
      agg.add(assistant(id: "c", cwd: "/Users/me/proj", model: "claude-opus-4-8",
        timestamp: "2026-06-08T01:00:00.000Z"))

      rows = agg.rows

      assert_equal 3, rows.size
      models = rows.map(&:model)
      assert_includes models, "opus-4-8"
      assert_includes models, "sonnet-4-6"
    end

    def test_sums_usage_within_a_group
      agg = Aggregator.new(timezone: :utc)
      agg.add(assistant(id: "a", cwd: "/Users/me/proj"))
      agg.add(assistant(id: "b", cwd: "/Users/me/proj"))

      row = agg.rows.first

      assert_equal 200, row.usage.input
      assert_equal 20, row.usage.output
      assert_equal 2000, row.usage.cache_read
    end

    def test_worktrees_collapse_into_their_repo
      agg = Aggregator.new(timezone: :utc)
      agg.add(assistant(id: "a", cwd: "/Users/me/teak/carrot"))
      agg.add(assistant(id: "b", cwd: "/Users/me/teak/carrot/.claude/worktrees/wt-1"))
      agg.add(assistant(id: "c", cwd: "/Users/me/tmp/worktrees/carrot/loose-name"))

      rows = agg.rows

      assert_equal 1, rows.size
      assert_equal "/Users/me/teak/carrot", rows.first.project
      assert_equal 300, rows.first.usage.input
    end

    def test_dated_and_undated_claude_models_collapse_into_one_row
      agg = Aggregator.new(timezone: :utc)
      agg.add(assistant(id: "a", cwd: "/Users/me/proj", model: "claude-haiku-4-5-20251001"))
      agg.add(assistant(id: "b", cwd: "/Users/me/proj", model: "claude-haiku-4-5"))

      rows = agg.rows

      assert_equal 1, rows.size
      assert_equal "haiku-4-5", rows.first.model
      assert_equal 200, rows.first.usage.input
    end

    def test_unknown_model_has_no_cost
      agg = Aggregator.new(timezone: :utc)
      agg.add(assistant(id: "a", cwd: "/Users/me/proj", model: "qwen3.6:27b-coding-nvfp4"))

      row = agg.rows.first

      assert_nil row.cost
      refute row.priced?
    end

    def test_known_model_is_costed
      agg = Aggregator.new(timezone: :utc)
      agg.add(assistant(id: "a", cwd: "/Users/me/proj", model: "claude-opus-4-8"))

      row = agg.rows.first

      assert row.priced?
      assert_operator row.cost, :>, 0
    end

    def test_ignores_non_assistant_and_usageless_records
      agg = Aggregator.new(timezone: :utc)
      agg.add("type" => "user", "message" => { "role" => "user" })
      agg.add("type" => "assistant", "message" => { "id" => "x", "model" => "claude-opus-4-8" })
      agg.add("type" => "system")

      assert_empty agg.rows
    end

    def test_missing_timestamp_buckets_as_unknown
      agg = Aggregator.new(timezone: :utc)
      agg.add(assistant(id: "a", cwd: "/Users/me/proj", timestamp: nil))

      assert_equal "unknown", agg.rows.first.date
    end
  end
end
