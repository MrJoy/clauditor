# frozen_string_literal: true

require "csv"
require "json"

module Clauditor
  # Rollup ("--rollup") views: the per-day breakdown collapsed to one row per
  # (project, model), usage and cost summed across the window. Works in table,
  # csv, and json. Costs are summed from the already-computed per-row costs (not
  # re-derived from summed usage) so tiered pricing stays correct across a
  # price-change boundary, and unpriced models stay unpriced.
  module Rollup
    module_function

    def for(name)
      case name.to_s
      when "table" then Table
      when "csv" then Csv
      when "json" then Json
      else
        raise ArgumentError, "unknown format: #{name}"
      end
    end

    # Collapses flat aggregator rows to one Row per (project, model), summing
    # usage and the already-computed per-row cost. A collapsed cell is unpriced
    # only when none of its component rows were priced. Sorted by project then
    # model; the date field is nil (this view has no date column).
    def collapse(rows)
      groups = Hash.new { |hash, key| hash[key] = [] }
      rows.each { |row| groups[[ row.project, row.model ]] << row }

      groups.map do |(project, model), group|
        priced = group.select(&:priced?)
        Aggregator::Row.new(
          project: project,
          date: nil,
          model: model,
          usage: group.map(&:usage).reduce(Usage.new, :+),
          cost: priced.empty? ? nil : priced.sum(&:cost),
        )
      end.sort_by { |row| [ row.project, row.model ] }
    end

    # Aligned, human-readable columns with a totals row — the flat table minus
    # the Date column.
    module Table
      module_function

      NUMERIC_HEADERS = [ "Input", "Output", "Cache Write", "Cache Read", "Cost" ].freeze

      # Token counts are abbreviated with k/m/b suffixes unless verbose (costs are
      # always shown in full), matching the --anthropic crosstab. hide_project /
      # hide_model drop the corresponding leading label column. This view has no
      # always-present label column, so if both would be dropped the Model label is
      # kept — a per-model rollup with no row labels is meaningless.
      def render(rows, verbose: false, hide_project: false, hide_model: false)
        cells = Rollup.collapse(rows)
        labels = label_headers(hide_project, hide_model)
        headers = labels + NUMERIC_HEADERS
        drop_model = !labels.include?("Model")
        table = cells.map { |cell| columns(cell, verbose, hide_project, drop_model) }
        table << totals_row(cells, verbose, labels.size)
        label_cols = labels.size

        widths = Formatters.column_widths(headers, table)
        lines = []
        lines << Formatters.format_row(headers, widths, label_cols)
        lines << Formatters.separator(widths)
        table.each_with_index do |cols, index|
          lines << Formatters.separator(widths) if index == table.size - 1
          lines << Formatters.format_row(cols, widths, label_cols)
        end
        "#{lines.join("\n")}\n"
      end

      # Project?, Model? — but never both dropped (Model is kept when dropping it
      # would leave no label column).
      def label_headers(hide_project, hide_model)
        headers = []
        headers << "Project" unless hide_project
        headers << "Model" unless hide_model
        headers.empty? ? [ "Model" ] : headers
      end

      def columns(row, verbose, hide_project, drop_model)
        labels = []
        labels << ProjectNormalizer.display(row.project) unless hide_project
        labels << row.model unless drop_model
        labels + [
          tokens(row.usage.input, verbose),
          tokens(row.usage.output, verbose),
          tokens(row.usage.cache_write, verbose),
          tokens(row.usage.cache_read, verbose),
          Formatters.cost_cell(row.cost),
        ]
      end

      def totals_row(cells, verbose, label_cols)
        usage = cells.map(&:usage).reduce(Usage.new, :+)
        priced_cells = cells.select(&:priced?)
        cost = priced_cells.empty? ? nil : priced_cells.sum(&:cost)
        labels = [ "TOTAL" ] + Array.new(label_cols - 1, "")
        labels + [
          tokens(usage.input, verbose),
          tokens(usage.output, verbose),
          tokens(usage.cache_write, verbose),
          tokens(usage.cache_read, verbose),
          Formatters.cost_cell(cost),
        ]
      end

      # Full delimited count when verbose, otherwise a k/m/b-abbreviated one.
      def tokens(value, verbose)
        verbose ? Formatters.delimit(value) : Formatters.scale(value)
      end
    end

    # Machine-readable rows; cost left blank for unpriced models.
    module Csv
      module_function

      # verbose, hide_project, and hide_model are accepted for a uniform interface but
      # ignored — CSV is always full precision and always carries the project and model.
      def render(rows, verbose: false, hide_project: false, hide_model: false)
        _ = verbose
        _ = hide_project
        _ = hide_model
        CSV.generate do |csv|
          csv << [
            "project",
            "model",
            "input_tokens",
            "output_tokens",
            "cache_creation_tokens",
            "cache_read_tokens",
            "total_tokens",
            "cost_usd",
          ]
          Rollup.collapse(rows).each do |row|
            csv << [
              ProjectNormalizer.display(row.project),
              row.model,
              row.usage.input,
              row.usage.output,
              row.usage.cache_write,
              row.usage.cache_read,
              row.usage.total,
              row.cost.nil? ? nil : format("%.4f", row.cost),
            ]
          end
        end
      end
    end

    # Pretty JSON array; cost_usd is null and priced=false for unknown models.
    module Json
      module_function

      # verbose, hide_project, and hide_model are accepted for a uniform interface but
      # ignored — JSON is always full precision and always carries the project and model.
      def render(rows, verbose: false, hide_project: false, hide_model: false)
        _ = verbose
        _ = hide_project
        _ = hide_model
        payload = Rollup.collapse(rows).map do |row|
          {
            project: ProjectNormalizer.display(row.project),
            model: row.model,
            input_tokens: row.usage.input,
            output_tokens: row.usage.output,
            cache_creation_tokens: row.usage.cache_write,
            cache_read_tokens: row.usage.cache_read,
            total_tokens: row.usage.total,
            cost_usd: row.cost.nil? ? nil : row.cost.round(4),
            priced: row.priced?,
          }
        end
        "#{JSON.pretty_generate(payload)}\n"
      end
    end
  end
end
