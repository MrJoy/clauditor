# frozen_string_literal: true

module Clauditor
  # Per-model token pricing (USD per million tokens) plus the cache
  # multipliers that turn a base input rate into cache read/write rates.
  #
  # Rates track Anthropic's published list pricing. Cache reads bill at 0.1x
  # the base input rate; 5-minute cache writes at 1.25x; 1-hour writes at 2x.
  #
  # A model's value is normally a flat `{ input:, output: }` rate hash. When a
  # model's list price changes on a known date, its value is instead an array
  # of tiers ordered oldest-first, each a rate hash plus an `until:` cutoff
  # ("YYYY-MM-DD", inclusive); the final tier carries no `until:` and applies
  # indefinitely. .rates_for resolves a tier from a cell's day.
  module Pricing
    # Base input/output rates in USD per million tokens, keyed by the
    # normalized model id (see .normalize_model — no "claude-" prefix, no date).
    RATES = {
      "fable-5" => { input: 10.0, output: 50.0 },
      "opus-4-8" => { input: 5.0, output: 25.0 },
      "opus-4-7" => { input: 5.0, output: 25.0 },
      "opus-4-6" => { input: 5.0, output: 25.0 },
      "opus-4-5" => { input: 5.0, output: 25.0 },
      "sonnet-5" => [
        { until: "2026-08-31", input: 2.0, output: 10.0 },
        { input: 3.0, output: 15.0 },
      ],
      "sonnet-4-6" => { input: 3.0, output: 15.0 },
      "sonnet-4-5" => { input: 3.0, output: 15.0 },
      "haiku-4-5" => { input: 1.0, output: 5.0 },
    }.freeze

    # Display order for model families: least to most capable/expensive.
    FAMILY_ORDER = %w[haiku sonnet opus fable].freeze

    CACHE_READ_MULTIPLIER = 0.1
    CACHE_WRITE_5M_MULTIPLIER = 1.25
    CACHE_WRITE_1H_MULTIPLIER = 2.0

    MILLION = 1_000_000.0

    module_function

    # Normalizes a Claude model id to a concise, distinctive name by dropping
    # the "claude-" prefix and any trailing date stamp
    # (e.g. "claude-haiku-4-5-20251001" => "haiku-4-5"), so dated/undated ids
    # group and price together and reports stay readable. Non-Claude ids are
    # returned untouched, in case their text is meaningful.
    def normalize_model(model)
      id = model.to_s
      return id unless id.start_with?("claude-")

      id.delete_prefix("claude-").sub(/-\d{8}\z/, "")
    end

    def known?(model)
      RATES.key?(normalize_model(model))
    end

    # Sort key ordering models by family (haiku < sonnet < opus < fable) then version
    # ascending, so `opus-4-7` precedes `opus-4-8`. Unknown families sort last,
    # alphabetically.
    def sort_key(model)
      family, *version = normalize_model(model).split("-")
      [ FAMILY_ORDER.index(family) || FAMILY_ORDER.size, family, version.map(&:to_i) ]
    end

    # Resolves the rate hash for a model on a given day. Date-independent
    # models return their flat hash regardless of `date`. Tiered models select
    # the first tier whose inclusive `until:` cutoff is on or after the day (the
    # open-ended final tier always matches). When the day is nil or "unknown"
    # — it can't be placed in time — the current, open-ended tier applies.
    def rates_for(model, date = nil)
      entry = RATES[normalize_model(model)]
      return entry unless entry.is_a?(Array)

      if date && date != "unknown"
        entry.find { |tier| tier[:until].nil? || date <= tier[:until] }
      else
        entry.last
      end
    end

    # USD cost for a Usage under the given model on the given day, or nil when
    # we have no rates for that model (e.g. local or synthetic models). The day
    # ("YYYY-MM-DD") selects the active rate tier for models whose list price
    # changes over time.
    def cost_for(model, usage, date = nil)
      rates = rates_for(model, date)
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
