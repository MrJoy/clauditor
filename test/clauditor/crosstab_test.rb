# frozen_string_literal: true

require "test_helper"
require "csv"

module Clauditor
  class CrosstabTest < Minitest::Test
    def row(project:, date:, model:, input:, cost:)
      Aggregator::Row.new(
        project: project,
        date: date,
        model: model,
        usage: Usage.new(input: input, output: 2, cache_read: 3, cache_write_5m: 4, cache_write_1h: 0),
        cost: cost,
      )
    end

    def rows
      [
        row(project: "/Users/me/a", date: "2026-06-07", model: "opus-4-8", input: 100, cost: 1.5),
        row(project: "/Users/me/a", date: "2026-06-07", model: "haiku-4-5", input: 10, cost: 0.2),
        row(project: "/Users/me/b", date: "2026-06-08", model: "opus-4-8", input: 50, cost: 0.9),
        # Non-Anthropic model must be excluded from the crosstab entirely.
        row(project: "/Users/me/b", date: "2026-06-08", model: "qwen3.6:27b-coding-nvfp4", input: 7, cost: nil),
      ]
    end

    def test_pivot_keeps_only_anthropic_models_sorted
      models, keys, cells = Crosstab.pivot(rows)

      assert_equal %w[haiku-4-5 opus-4-8], models
      assert_equal [ [ "2026-06-07", "/Users/me/a" ], [ "2026-06-08", "/Users/me/b" ] ], keys
      assert_equal 100, cells[[ "2026-06-07", "/Users/me/a" ]]["opus-4-8"].usage.input
      refute keys.include?([ "2026-06-08", "/Users/me/b" ]) && cells[[ "2026-06-08", "/Users/me/b" ]].key?("qwen3.6:27b-coding-nvfp4")
    end

    def test_pivot_orders_columns_by_family_then_version
      varied = [
        row(project: "/Users/me/a", date: "2026-06-07", model: "opus-4-8", input: 1, cost: 0.1),
        row(project: "/Users/me/a", date: "2026-06-07", model: "opus-4-7", input: 1, cost: 0.1),
        row(project: "/Users/me/a", date: "2026-06-07", model: "sonnet-4-6", input: 1, cost: 0.1),
        row(project: "/Users/me/a", date: "2026-06-07", model: "haiku-4-5", input: 1, cost: 0.1),
      ]

      models, = Crosstab.pivot(varied)

      assert_equal %w[haiku-4-5 sonnet-4-6 opus-4-7 opus-4-8], models
    end

    def test_table_has_spanning_model_header_and_subcolumns
      lines = Crosstab::Table.render(rows).lines

      top = lines[0]
      sub = lines[1]
      assert_includes top, "opus-4-8"
      assert_includes top, "haiku-4-5"
      assert_includes sub, "Tokens"
      assert_includes sub, "Cost"
      # The model name on the top line sits above its own pair of columns.
      assert_operator top.index("opus-4-8"), :>, top.index("haiku-4-5")
    end

    def test_table_totals_each_model_column
      total_line = Crosstab::Table.render(rows).lines.find { |line| line.start_with?("TOTAL") }

      # haiku appears once (cost 0.2); opus twice (1.5 + 0.9 = 2.4).
      assert_includes total_line, "$0.20"
      assert_includes total_line, "$2.40"
    end

    def test_table_one_row_per_day_project
      data_lines = Crosstab::Table.render(rows).lines.select { |l| l =~ /^\d{4}-\d{2}-\d{2}/ }

      assert_equal 2, data_lines.size
    end

    def test_csv_prefixes_five_metric_columns_per_model
      table = CSV.parse(Crosstab::Csv.render(rows), headers: true)

      assert_equal "date", table.headers.first
      assert_includes table.headers, "opus-4-8 Input"
      assert_includes table.headers, "opus-4-8 Cost"
      assert_includes table.headers, "haiku-4-5 Cache Write"
      refute(table.headers.any? { |h| h.start_with?("qwen") })
    end

    def test_csv_blanks_models_absent_from_a_row
      table = CSV.parse(Crosstab::Csv.render(rows), headers: true)
      row_b = table.find { |r| r["project"] == "/Users/me/b" }

      assert_equal "50", row_b["opus-4-8 Input"]
      assert_nil row_b["haiku-4-5 Input"]
    end
  end
end
