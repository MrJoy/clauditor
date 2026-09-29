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

    def test_cost_for_applies_sonnet_5_rates_before_and_after_the_cancelled_increase
      usage = Usage.new(input: 1_000_000, output: 1_000_000, cache_read: 1_000_000)

      expected = 2.0 + 10.0 + 0.2 # the scheduled 2026-09-01 move to $3/$15 never happened

      [ "2026-06-30", "2026-09-01", "2027-01-15", nil ].each do |day|
        assert_in_delta expected, Pricing.cost_for("claude-sonnet-5", usage, day), 1e-9
      end
    end

    def test_cost_for_applies_sonnet_5_5_rates
      usage = Usage.new(input: 1_000_000, output: 1_000_000, cache_read: 1_000_000,
        cache_write_5m: 1_000_000, cache_write_1h: 1_000_000)

      expected = 2.0 + 10.0 + 0.2 + 2.5 + 4.0

      assert_in_delta expected, Pricing.cost_for("claude-sonnet-5-5", usage), 1e-9
    end

    def test_known_and_sort_key_place_sonnet_5_5_after_sonnet_5
      assert Pricing.known?("claude-sonnet-5-5")
      assert_equal %w[sonnet-4-6 sonnet-5 sonnet-5-5 opus-4-8],
        %w[opus-4-8 sonnet-5-5 sonnet-4-6 sonnet-5].sort_by { |model| Pricing.sort_key(model) }
    end

    TIERS = [
      { until: "2026-08-31", input: 2.0, output: 10.0 },
      { input: 3.0, output: 15.0 },
    ].freeze

    def test_tier_for_uses_earlier_tier_through_its_inclusive_cutoff
      assert_equal 2.0, Pricing.tier_for(TIERS, "2026-08-31")[:input]
      assert_equal 2.0, Pricing.tier_for(TIERS, "2026-06-30")[:input]
    end

    def test_tier_for_uses_open_ended_tier_after_the_cutoff
      assert_equal 3.0, Pricing.tier_for(TIERS, "2026-09-01")[:input]
    end

    def test_tier_for_defaults_to_current_tier_without_a_placeable_day
      assert_equal 3.0, Pricing.tier_for(TIERS, nil)[:input]
      assert_equal 3.0, Pricing.tier_for(TIERS, "unknown")[:input]
    end

    def test_known_and_sort_key_handle_sonnet_5
      assert Pricing.known?("claude-sonnet-5")
      assert_equal [ 1, "sonnet", [ 5 ] ], Pricing.sort_key("claude-sonnet-5")
    end

    def test_cost_for_applies_opus_5_rates
      usage = Usage.new(input: 1_000_000, output: 1_000_000, cache_read: 1_000_000,
        cache_write_5m: 1_000_000, cache_write_1h: 1_000_000)

      expected = 5.0 + 25.0 + (5.0 * 0.1) + (5.0 * 1.25) + (5.0 * 2.0)

      assert_in_delta expected, Pricing.cost_for("claude-opus-5", usage), 1e-9
    end

    def test_known_and_sort_key_place_opus_5_after_opus_4_8
      assert Pricing.known?("claude-opus-5")
      assert_equal [ 2, "opus", [ 5 ] ], Pricing.sort_key("claude-opus-5")
      assert_equal %w[opus-4-7 opus-4-8 opus-5 fable-5],
        %w[opus-5 fable-5 opus-4-8 opus-4-7].sort_by { |model| Pricing.sort_key(model) }
    end

    def test_cost_for_applies_fable_5_1_rates_with_flat_cache_read_rate
      usage = Usage.new(input: 1_000_000, output: 1_000_000, cache_read: 1_000_000,
        cache_write_5m: 1_000_000, cache_write_1h: 1_000_000)

      # Cache reads are a flat $0.25/MTok (0.025x input), not the usual 0.1x.
      expected = 10.0 + 50.0 + 0.25 + (10.0 * 1.25) + (10.0 * 2.0)

      assert_in_delta expected, Pricing.cost_for("claude-fable-5-1", usage), 1e-9
    end

    def test_known_and_sort_key_place_fable_5_1_after_fable_5
      assert Pricing.known?("claude-fable-5-1")
      assert_equal [ 3, "fable", [ 5, 1 ] ], Pricing.sort_key("claude-fable-5-1")
      assert_equal %w[opus-5 fable-5 fable-5-1],
        %w[fable-5-1 fable-5 opus-5].sort_by { |model| Pricing.sort_key(model) }
    end

    def test_cost_for_applies_opus_5_5_rates_with_flat_cache_read_rate
      usage = Usage.new(input: 1_000_000, output: 1_000_000, cache_read: 1_000_000,
        cache_write_5m: 1_000_000, cache_write_1h: 1_000_000)

      # Cache reads are a flat $0.20/MTok (0.05x input), not the usual 0.1x.
      expected = 4.0 + 20.0 + 0.20 + (4.0 * 1.25) + (4.0 * 2.0)

      assert_in_delta expected, Pricing.cost_for("claude-opus-5-5", usage), 1e-9
    end

    def test_known_and_sort_key_place_opus_5_5_after_opus_5
      assert Pricing.known?("claude-opus-5-5")
      assert_equal [ 2, "opus", [ 5, 5 ] ], Pricing.sort_key("claude-opus-5-5")
      assert_equal %w[opus-4-8 opus-5 opus-5-5 fable-5-1],
        %w[fable-5-1 opus-5-5 opus-4-8 opus-5].sort_by { |model| Pricing.sort_key(model) }
    end
  end
end
