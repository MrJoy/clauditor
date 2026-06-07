# frozen_string_literal: true

module Clauditor
  # Tallies the billable token dimensions for one or more messages.
  #
  # Claude Code reports cache-creation tokens both as a single
  # `cache_creation_input_tokens` total and as a TTL split under
  # `cache_creation` (`ephemeral_5m_input_tokens` / `ephemeral_1h_input_tokens`).
  # We keep the split because 5-minute and 1-hour cache writes are priced
  # differently; the `cache_write` accessor re-sums them for display.
  class Usage
    attr_reader :input, :output, :cache_read, :cache_write_5m, :cache_write_1h

    def initialize(input: 0, output: 0, cache_read: 0, cache_write_5m: 0, cache_write_1h: 0)
      @input = input
      @output = output
      @cache_read = cache_read
      @cache_write_5m = cache_write_5m
      @cache_write_1h = cache_write_1h
    end

    # Builds a Usage from a raw `message.usage` hash.
    def self.from_message_usage(usage)
      creation = usage["cache_creation"]
      if creation
        cw5m = creation["ephemeral_5m_input_tokens"].to_i
        cw1h = creation["ephemeral_1h_input_tokens"].to_i
      else
        # Older records only carry the total; treat it as a 5-minute write.
        cw5m = usage["cache_creation_input_tokens"].to_i
        cw1h = 0
      end

      new(
        input: usage["input_tokens"].to_i,
        output: usage["output_tokens"].to_i,
        cache_read: usage["cache_read_input_tokens"].to_i,
        cache_write_5m: cw5m,
        cache_write_1h: cw1h,
      )
    end

    # Total cache-creation tokens across both TTLs (the display dimension).
    def cache_write
      cache_write_5m + cache_write_1h
    end

    def total
      input + output + cache_read + cache_write
    end

    def +(other)
      self.class.new(
        input: input + other.input,
        output: output + other.output,
        cache_read: cache_read + other.cache_read,
        cache_write_5m: cache_write_5m + other.cache_write_5m,
        cache_write_1h: cache_write_1h + other.cache_write_1h,
      )
    end
  end
end
