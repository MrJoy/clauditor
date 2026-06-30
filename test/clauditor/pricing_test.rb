# frozen_string_literal: true

require "test_helper"

module Clauditor
  class PricingTest < Minitest::Test
    def test_normalize_model_strips_claude_prefix_and_date_for_claude_ids
      assert_equal "haiku-4-5", Pricing.normalize_model("claude-haiku-4-5-20251001")
      assert_equal "opus-4-8", Pricing.normalize_model("claude-opus-4-8")
    end

    def test_normalize_model_leaves_non_claude_ids_untouched
      assert_equal "qwen3.6:27b-coding-nvfp4", Pricing.normalize_model("qwen3.6:27b-coding-nvfp4")
      assert_equal "local-model-20251001", Pricing.normalize_model("local-model-20251001")
    end

    def test_known_handles_dated_and_unknown_models
      assert Pricing.known?("claude-haiku-4-5-20251001")
      assert Pricing.known?("claude-opus-4-8")
      assert Pricing.known?("claude-fable-5")
      refute Pricing.known?("qwen3.6:27b-coding-nvfp4")
      refute Pricing.known?("<synthetic>")
    end

    def test_cost_for_applies_fable_5_rates
      usage = Usage.new(input: 1_000_000, output: 1_000_000)

      expected = 10.0 + 50.0 # input + output at $10/$50 per MTok

      assert_in_delta expected, Pricing.cost_for("claude-fable-5", usage), 1e-9
    end

    def test_cost_for_applies_base_and_cache_multipliers
      # One million of each dimension makes the math easy to read against the
      # opus rate ($5 input / $25 output) and cache multipliers.
      usage = Usage.new(
        input: 1_000_000,
        output: 1_000_000,
        cache_read: 1_000_000,
        cache_write_5m: 1_000_000,
        cache_write_1h: 1_000_000,
      )

      expected =
        5.0 +            # input
        25.0 +           # output
        (5.0 * 0.1) +    # cache read
        (5.0 * 1.25) +   # 5m cache write
        (5.0 * 2.0)      # 1h cache write

      assert_in_delta expected, Pricing.cost_for("claude-opus-4-8", usage), 1e-9
    end

    def test_sort_key_orders_by_family_then_version
      models = %w[opus-4-8 haiku-4-5 fable-5 opus-4-7 sonnet-4-6 sonnet-4-5]

      assert_equal %w[haiku-4-5 sonnet-4-5 sonnet-4-6 opus-4-7 opus-4-8 fable-5],
        models.sort_by { |model| Pricing.sort_key(model) }
    end

    def test_sort_key_normalizes_before_ordering
      # A raw, dated claude id sorts the same as its normalized form.
      assert_equal Pricing.sort_key("opus-4-8"), Pricing.sort_key("claude-opus-4-8")
    end

    def test_cost_for_returns_nil_for_unknown_model
      usage = Usage.new(input: 1_000_000)

      assert_nil Pricing.cost_for("qwen3.6:27b-coding-nvfp4", usage)
    end

    def test_cost_for_applies_sonnet_5_introductory_rates_through_august
      usage = Usage.new(input: 1_000_000, output: 1_000_000)

      expected = 2.0 + 10.0 # $2/$10 per MTok through 2026-08-31

      assert_in_delta expected, Pricing.cost_for("claude-sonnet-5", usage, "2026-08-31"), 1e-9
      assert_in_delta expected, Pricing.cost_for("claude-sonnet-5", usage, "2026-06-30"), 1e-9
    end

    def test_cost_for_applies_sonnet_5_standard_rates_from_september
      usage = Usage.new(input: 1_000_000, output: 1_000_000)

      expected = 3.0 + 15.0 # $3/$15 per MTok from 2026-09-01

      assert_in_delta expected, Pricing.cost_for("claude-sonnet-5", usage, "2026-09-01"), 1e-9
      assert_in_delta expected, Pricing.cost_for("claude-sonnet-5", usage, "2027-01-15"), 1e-9
    end

    def test_cost_for_sonnet_5_defaults_to_current_tier_without_date
      usage = Usage.new(input: 1_000_000, output: 1_000_000)

      standard = 3.0 + 15.0 # open-ended tier when the day can't be placed in time

      assert_in_delta standard, Pricing.cost_for("claude-sonnet-5", usage), 1e-9
      assert_in_delta standard, Pricing.cost_for("claude-sonnet-5", usage, "unknown"), 1e-9
    end

    def test_known_and_sort_key_handle_sonnet_5
      assert Pricing.known?("claude-sonnet-5")
      assert_equal [ 1, "sonnet", [ 5 ] ], Pricing.sort_key("claude-sonnet-5")
    end
  end
end
