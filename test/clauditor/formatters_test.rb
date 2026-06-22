# frozen_string_literal: true

require "test_helper"
require "json"
require "csv"

module Clauditor
  class FormattersTest < Minitest::Test
    def rows
      [
        Aggregator::Row.new(
          project: File.join(Dir.home, "teak/carrot"),
          date: "2026-06-07",
          model: "opus-4-8",
          usage: Usage.new(input: 1234, output: 56, cache_read: 7890, cache_write_5m: 12, cache_write_1h: 0),
          cost: 1234.5678,
        ),
        Aggregator::Row.new(
          project: "/Users/me/proj",
          date: "2026-06-07",
          model: "qwen3.6:27b-coding-nvfp4",
          usage: Usage.new(input: 5, output: 5),
          cost: nil,
        ),
      ]
    end

    def test_delimit_inserts_thousands_separators
      assert_equal "1,234,567", Formatters.delimit(1_234_567)
      assert_equal "0", Formatters.delimit(0)
    end

    def test_scale_abbreviates_with_suffixes
      assert_equal "999", Formatters.scale(999)
      assert_equal "1.0k", Formatters.scale(1000)
      assert_equal "58.1k", Formatters.scale(58_078)
      assert_equal "1.2m", Formatters.scale(1_234_567)
      assert_equal "185.3m", Formatters.scale(185_287_171)
      assert_equal "2.0b", Formatters.scale(2_000_000_000)
    end

    def test_table_renders_headers_totals_and_costs
      output = Formatters::Table.render(rows)

      assert_includes output, "Project"
      assert_includes output, "~/teak/carrot"
      assert_includes output, "1,234"
      assert_includes output, "$1,234.57"
      assert_includes output, "TOTAL"
      assert_includes output, "—" # unpriced model
    end

    def test_table_drops_project_column_when_hidden
      output = Formatters::Table.render(rows, hide_project: true)
      header = output.lines.first

      refute_includes header, "Project"
      refute_includes output, "~/teak/carrot"
      assert header.start_with?("Date"), "Date should lead the header, got: #{header.inspect}"
      assert_includes output, "Model"
      assert_includes output, "TOTAL" # totals label survives in the Date column
      assert_includes output, "$1,234.57"
    end

    def test_csv_ignores_hide_project
      assert_equal Formatters::Csv.render(rows), Formatters::Csv.render(rows, hide_project: true)
    end

    def test_json_ignores_hide_project
      assert_equal Formatters::Json.render(rows), Formatters::Json.render(rows, hide_project: true)
    end

    def test_csv_has_header_and_blank_cost_for_unpriced
      output = Formatters::Csv.render(rows)
      table = CSV.parse(output, headers: true)

      assert_equal %w[project date model input_tokens output_tokens cache_creation_tokens
        cache_read_tokens total_tokens cost_usd], table.headers
      priced = table.find { |r| r["model"] == "opus-4-8" }
      unpriced = table.find { |r| r["model"] == "qwen3.6:27b-coding-nvfp4" }

      assert_equal "1234.5678", priced["cost_usd"]
      assert_nil unpriced["cost_usd"]
    end

    def test_json_marks_priced_flag_and_nulls_cost
      payload = JSON.parse(Formatters::Json.render(rows))

      priced = payload.find { |r| r["model"] == "opus-4-8" }
      unpriced = payload.find { |r| r["model"] == "qwen3.6:27b-coding-nvfp4" }

      assert_equal true, priced["priced"]
      assert_in_delta 1234.5678, priced["cost_usd"], 1e-4
      assert_equal false, unpriced["priced"]
      assert_nil unpriced["cost_usd"]
    end
  end
end
