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

      HEADERS = [
        "Project",
        "Model",
        "Input",
        "Output",
        "Cache Write",
        "Cache Read",
        "Cost",
      ].freeze

      # hide_project drops the leading Project column (single-project output).
      def render(rows, hide_project: false)
        cells = Rollup.collapse(rows)
        headers = hide_project ? HEADERS.drop(1) : HEADERS
        table = cells.map { |cell| columns(cell, hide_project) }
        table << totals_row(cells, hide_project)
        label_cols = hide_project ? 1 : 2

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

      def columns(row, hide_project)
        labels = hide_project ? [ row.model ] : [ ProjectNormalizer.display(row.project), row.model ]
        labels + [
          Formatters.delimit(row.usage.input),
          Formatters.delimit(row.usage.output),
          Formatters.delimit(row.usage.cache_write),
          Formatters.delimit(row.usage.cache_read),
          Formatters.cost_cell(row.cost),
        ]
      end

      def totals_row(cells, hide_project)
        usage = cells.map(&:usage).reduce(Usage.new, :+)
        priced_cells = cells.select(&:priced?)
        cost = priced_cells.empty? ? nil : priced_cells.sum(&:cost)
        labels = hide_project ? [ "TOTAL" ] : [ "TOTAL", "" ]
        labels + [
          Formatters.delimit(usage.input),
          Formatters.delimit(usage.output),
          Formatters.delimit(usage.cache_write),
          Formatters.delimit(usage.cache_read),
          Formatters.cost_cell(cost),
        ]
      end
    end
  end
end
