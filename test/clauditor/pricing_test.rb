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
      refute Pricing.known?("qwen3.6:27b-coding-nvfp4")
      refute Pricing.known?("<synthetic>")
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
      models = %w[opus-4-8 haiku-4-5 opus-4-7 sonnet-4-6 sonnet-4-5]

      assert_equal %w[haiku-4-5 sonnet-4-5 sonnet-4-6 opus-4-7 opus-4-8],
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
  end
end
