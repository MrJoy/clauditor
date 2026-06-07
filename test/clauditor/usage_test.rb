# frozen_string_literal: true

require "test_helper"

module Clauditor
  class UsageTest < Minitest::Test
    def test_from_message_usage_reads_all_dimensions_with_ttl_split
      usage = Usage.from_message_usage(
        "input_tokens" => 2477,
        "output_tokens" => 296,
        "cache_read_input_tokens" => 17_000,
        "cache_creation_input_tokens" => 2650,
        "cache_creation" => {
          "ephemeral_5m_input_tokens" => 650,
          "ephemeral_1h_input_tokens" => 2000,
        },
      )

      assert_equal 2477, usage.input
      assert_equal 296, usage.output
      assert_equal 17_000, usage.cache_read
      assert_equal 650, usage.cache_write_5m
      assert_equal 2000, usage.cache_write_1h
      assert_equal 2650, usage.cache_write
    end

    def test_from_message_usage_without_ttl_split_treats_total_as_5m
      usage = Usage.from_message_usage(
        "input_tokens" => 10,
        "output_tokens" => 5,
        "cache_creation_input_tokens" => 40,
      )

      assert_equal 40, usage.cache_write_5m
      assert_equal 0, usage.cache_write_1h
      assert_equal 40, usage.cache_write
    end

    def test_addition_sums_each_dimension
      a = Usage.new(input: 1, output: 2, cache_read: 3, cache_write_5m: 4, cache_write_1h: 5)
      b = Usage.new(input: 10, output: 20, cache_read: 30, cache_write_5m: 40, cache_write_1h: 50)
      sum = a + b

      assert_equal 11, sum.input
      assert_equal 22, sum.output
      assert_equal 33, sum.cache_read
      assert_equal 44, sum.cache_write_5m
      assert_equal 55, sum.cache_write_1h
    end

    def test_total_counts_every_billable_dimension
      usage = Usage.new(input: 1, output: 2, cache_read: 3, cache_write_5m: 4, cache_write_1h: 5)

      assert_equal 1 + 2 + 3 + 4 + 5, usage.total
    end
  end
end
