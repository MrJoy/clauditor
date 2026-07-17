# frozen_string_literal: true

require "test_helper"
require "csv"

module Clauditor
  class RollupTest < Minitest::Test
    def row(project:, date:, model:, input:, cost:)
      Aggregator::Row.new(
        project: project,
        date: date,
        model: model,
        usage: Usage.new(input: input, output: 2, cache_read: 3, cache_write_5m: 4, cache_write_1h: 0),
        cost: cost,
      )
    end

    def test_collapse_sums_usage_and_cost_across_dates
      rows = [
        row(project: "/Users/me/a", date: "2026-06-07", model: "opus-4-8", input: 100, cost: 1.5),
        row(project: "/Users/me/a", date: "2026-06-08", model: "opus-4-8", input: 50, cost: 0.9),
      ]

      cells = Rollup.collapse(rows)

      assert_equal 1, cells.size
      assert_nil cells.first.date
      assert_equal 150, cells.first.usage.input
      assert_in_delta 2.4, cells.first.cost, 1e-9
    end

    def test_collapse_groups_by_project_and_model_sorted
      rows = [
        row(project: "/Users/me/b", date: "2026-06-07", model: "opus-4-8", input: 1, cost: 0.1),
        row(project: "/Users/me/a", date: "2026-06-07", model: "sonnet-5", input: 1, cost: 0.1),
        row(project: "/Users/me/a", date: "2026-06-07", model: "opus-4-8", input: 1, cost: 0.1),
      ]

      keys = Rollup.collapse(rows).map { |r| [ r.project, r.model ] }

      assert_equal [
        [ "/Users/me/a", "opus-4-8" ],
        [ "/Users/me/a", "sonnet-5" ],
        [ "/Users/me/b", "opus-4-8" ],
      ], keys
    end

    def test_collapse_unpriced_only_when_no_component_priced
      rows = [
        row(project: "/Users/me/a", date: "2026-06-07", model: "qwen", input: 5, cost: nil),
        row(project: "/Users/me/a", date: "2026-06-08", model: "qwen", input: 7, cost: nil),
      ]

      cell = Rollup.collapse(rows).first

      assert_nil cell.cost
      refute cell.priced?
    end

    def test_table_renders_project_model_and_totals
      rows = [
        row(project: "/Users/me/a", date: "2026-06-07", model: "opus-4-8", input: 100, cost: 1.5),
        row(project: "/Users/me/a", date: "2026-06-08", model: "opus-4-8", input: 50, cost: 0.9),
      ]

      lines = Rollup::Table.render(rows).lines

      assert_includes lines[0], "Project"
      assert_includes lines[0], "Model"
      refute_includes lines[0], "Date"
      data = lines.find { |l| l.include?("opus-4-8") && !l.start_with?("TOTAL") }
      assert_includes data, "150"
      total = lines.find { |l| l.start_with?("TOTAL") }
      assert_includes total, "$2.40"
    end

    def test_table_drops_project_column_when_hidden
      rows = [ row(project: "/Users/me/a", date: "2026-06-07", model: "opus-4-8", input: 100, cost: 1.5) ]

      lines = Rollup::Table.render(rows, hide_project: true).lines

      refute_includes lines[0], "Project"
      assert lines[0].start_with?("Model"), "Model should lead the header"
      refute(lines.any? { |line| line.include?("/Users/me/a") })
      assert(lines.any? { |line| line.start_with?("TOTAL") })
    end

    def test_table_unpriced_cost_renders_dash
      rows = [ row(project: "/Users/me/a", date: "2026-06-07", model: "qwen", input: 5, cost: nil) ]

      data = Rollup::Table.render(rows).lines.find { |l| l.include?("qwen") }

      assert_includes data, "—"
    end

    def test_table_total_renders_dash_when_all_rows_unpriced
      rows = [
        row(project: "/Users/me/a", date: "2026-06-07", model: "qwen", input: 5, cost: nil),
        row(project: "/Users/me/a", date: "2026-06-08", model: "qwen", input: 7, cost: nil),
      ]

      total = Rollup::Table.render(rows).lines.find { |l| l.start_with?("TOTAL") }

      assert_includes total, "—"
      refute_includes total, "$0.00"
    end
  end
end
