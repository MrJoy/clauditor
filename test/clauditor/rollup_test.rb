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

    def test_csv_has_project_model_and_no_date_column
      rows = [
        row(project: "/Users/me/a", date: "2026-06-07", model: "opus-4-8", input: 100, cost: 1.5),
        row(project: "/Users/me/a", date: "2026-06-08", model: "opus-4-8", input: 50, cost: 0.9),
      ]

      table = CSV.parse(Rollup::Csv.render(rows), headers: true)

      assert_equal %w[project model input_tokens output_tokens cache_creation_tokens cache_read_tokens total_tokens cost_usd], table.headers
      refute_includes table.headers, "date"
      assert_equal 1, table.size
      assert_equal "150", table.first["input_tokens"]
      assert_equal "2.4000", table.first["cost_usd"]
    end

    def test_csv_blanks_cost_for_unpriced_model
      rows = [ row(project: "/Users/me/a", date: "2026-06-07", model: "qwen", input: 5, cost: nil) ]

      table = CSV.parse(Rollup::Csv.render(rows), headers: true)

      assert_nil table.first["cost_usd"]
    end

    def test_json_collapses_to_per_project_model
      rows = [
        row(project: "/Users/me/a", date: "2026-06-07", model: "opus-4-8", input: 100, cost: 1.5),
        row(project: "/Users/me/a", date: "2026-06-08", model: "opus-4-8", input: 50, cost: 0.9),
      ]

      payload = JSON.parse(Rollup::Json.render(rows))

      assert_equal 1, payload.size
      refute payload.first.key?("date")
      assert_equal 150, payload.first["input_tokens"]
      assert_in_delta 2.4, payload.first["cost_usd"], 1e-9
      assert_equal true, payload.first["priced"]
    end

    def test_json_marks_unpriced_model
      rows = [ row(project: "/Users/me/a", date: "2026-06-07", model: "qwen", input: 5, cost: nil) ]

      payload = JSON.parse(Rollup::Json.render(rows))

      assert_nil payload.first["cost_usd"]
      assert_equal false, payload.first["priced"]
    end

    def test_for_dispatches_by_format_name
      assert_equal Rollup::Table, Rollup.for("table")
      assert_equal Rollup::Csv, Rollup.for("csv")
      assert_equal Rollup::Json, Rollup.for("json")
      assert_raises(ArgumentError) { Rollup.for("xml") }
    end

    def test_table_abbreviates_tokens_by_default
      rows = [ row(project: "/Users/me/a", date: "2026-06-07", model: "opus-4-8", input: 1_999_980, cost: 9.0) ]

      output = Rollup::Table.render(rows)

      assert_includes output, "2.0m"          # 1,999,980 abbreviated
      refute_includes output, "1,999,980"
      assert_includes output, "$9.00"         # cost is never abbreviated
    end

    def test_table_verbose_shows_full_token_counts
      rows = [ row(project: "/Users/me/a", date: "2026-06-07", model: "opus-4-8", input: 1_999_980, cost: 9.0) ]

      output = Rollup::Table.render(rows, verbose: true)

      assert_includes output, "1,999,980"
      refute_includes output, "2.0m"
    end

    def test_table_abbreviates_the_totals_row
      rows = [
        row(project: "/Users/me/a", date: "2026-06-07", model: "opus-4-8", input: 1_000_000, cost: 1.0),
        row(project: "/Users/me/a", date: "2026-06-08", model: "opus-4-8", input: 1_000_000, cost: 1.0),
      ]

      total = Rollup::Table.render(rows).lines.find { |l| l.start_with?("TOTAL") }

      assert_includes total, "2.0m"           # 1,000,000 + 1,000,000 summed then abbreviated
      refute_includes total, "2,000,000"
    end

    def test_csv_ignores_verbose
      rows = [ row(project: "/Users/me/a", date: "2026-06-07", model: "opus-4-8", input: 1_999_980, cost: 9.0) ]

      assert_equal Rollup::Csv.render(rows), Rollup::Csv.render(rows, verbose: true)
      assert_includes Rollup::Csv.render(rows, verbose: true), "1999980"
    end

    def test_json_ignores_verbose
      rows = [ row(project: "/Users/me/a", date: "2026-06-07", model: "opus-4-8", input: 1_999_980, cost: 9.0) ]

      assert_equal Rollup::Json.render(rows), Rollup::Json.render(rows, verbose: true)
    end

    def test_table_drops_model_column_when_hidden
      rows = [
        row(project: "/Users/me/a", date: "2026-06-07", model: "opus-4-8", input: 100, cost: 1.5),
        row(project: "/Users/me/b", date: "2026-06-07", model: "opus-4-8", input: 50, cost: 0.9),
      ]

      lines = Rollup::Table.render(rows, hide_model: true).lines

      assert_includes lines[0], "Project"
      refute_includes lines[0], "Model"
      refute(lines.any? { |line| line.include?("opus-4-8") })
      assert(lines.any? { |line| line.start_with?("TOTAL") })
    end

    def test_table_both_hidden_keeps_model_label
      rows = [ row(project: "/Users/me/a", date: "2026-06-07", model: "opus-4-8", input: 100, cost: 1.5) ]

      lines = Rollup::Table.render(rows, hide_project: true, hide_model: true).lines

      # No always-present label column exists here, so Model is kept rather than
      # leaving the view with no row labels at all.
      refute_includes lines[0], "Project"
      assert lines[0].start_with?("Model"), "Model label should be kept, got: #{lines[0].inspect}"
      assert(lines.any? { |line| line.include?("opus-4-8") })
      assert(lines.any? { |line| line.start_with?("TOTAL") })
    end

    def test_csv_ignores_hide_model
      rows = [ row(project: "/Users/me/a", date: "2026-06-07", model: "opus-4-8", input: 100, cost: 1.5) ]
      assert_equal Rollup::Csv.render(rows), Rollup::Csv.render(rows, hide_model: true)
    end

    def test_json_ignores_hide_model
      rows = [ row(project: "/Users/me/a", date: "2026-06-07", model: "opus-4-8", input: 100, cost: 1.5) ]
      assert_equal Rollup::Json.render(rows), Rollup::Json.render(rows, hide_model: true)
    end
  end
end
