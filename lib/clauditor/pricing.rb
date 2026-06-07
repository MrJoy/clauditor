# frozen_string_literal: true

module Clauditor
  # Per-model token pricing (USD per million tokens) plus the cache
  # multipliers that turn a base input rate into cache read/write rates.
  #
  # Rates track Anthropic's published list pricing. Cache reads bill at 0.1x
  # the base input rate; 5-minute cache writes at 1.25x; 1-hour writes at 2x.
  module Pricing
    # Base input/output rates in USD per million tokens, keyed by the
    # date-stripped model id (see .normalize_model).
    RATES = {
      "claude-opus-4-8" => { input: 5.0, output: 25.0 },
      "claude-opus-4-7" => { input: 5.0, output: 25.0 },
      "claude-opus-4-6" => { input: 5.0, output: 25.0 },
      "claude-opus-4-5" => { input: 5.0, output: 25.0 },
      "claude-sonnet-4-6" => { input: 3.0, output: 15.0 },
      "claude-sonnet-4-5" => { input: 3.0, output: 15.0 },
      "claude-haiku-4-5" => { input: 1.0, output: 5.0 },
    }.freeze

    CACHE_READ_MULTIPLIER = 0.1
    CACHE_WRITE_5M_MULTIPLIER = 1.25
    CACHE_WRITE_1H_MULTIPLIER = 2.0

    MILLION = 1_000_000.0

    module_function

    # Strips a trailing date stamp (e.g. "claude-haiku-4-5-20251001") so dated
    # and undated model ids resolve to the same rate entry.
    def normalize_model(model)
      model.to_s.sub(/-\d{8}\z/, "")
    end

    def known?(model)
      RATES.key?(normalize_model(model))
    end

    def rates_for(model)
      RATES[normalize_model(model)]
    end

    # USD cost for a Usage under the given model, or nil when we have no rates
    # for that model (e.g. local or synthetic models).
    def cost_for(model, usage)
      rates = rates_for(model)
      return nil unless rates

      input_rate = rates[:input]
      (
        usage.input * input_rate +
        usage.output * rates[:output] +
        usage.cache_read * input_rate * CACHE_READ_MULTIPLIER +
        usage.cache_write_5m * input_rate * CACHE_WRITE_5M_MULTIPLIER +
        usage.cache_write_1h * input_rate * CACHE_WRITE_1H_MULTIPLIER
      ) / MILLION
    end
  end
end
