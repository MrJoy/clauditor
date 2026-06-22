# frozen_string_literal: true

require "csv"

module Clauditor
  # Crosstab ("--anthropic") views: one row per (day, project), with each
  # Anthropic model spread across its own columns. Non-Anthropic models (and the
  # already-dropped <synthetic> turns) don't appear — the whole point of the
  # flag is an Anthropic-only, model-by-model breakdown.
  module Crosstab
    module_function

    LABELS = %w[Date Project].freeze
    GAP = "  "

    def for(name)
      case name.to_s
      when "table" then Table
      when "csv" then Csv
      else
        raise ArgumentError, "unknown format: #{name}"
      end
    end

    # Pivots flat aggregator rows into crosstab shape. Returns
    # [models, keys, cells]:
    #   models — sorted Anthropic model ids present in the data
    #   keys   — sorted [date, project] pairs, one per output row
    #   cells  — { [date, project] => { model => Aggregator::Row } }
    def pivot(rows)
      priced = rows.select { |row| Pricing.known?(row.model) }
      models = priced.map(&:model).uniq.sort_by { |model| Pricing.sort_key(model) }
      cells = Hash.new { |hash, key| hash[key] = {} }
      priced.each { |row| cells[[ row.date, row.project ]][row.model] = row }
      [ models, cells.keys.sort, cells ]
    end

    # Aligned table with a two-line header: each model name spans its pair of
    # (Tokens, Cost) columns on the top line, the sub-column names sit below.
    module Table
      module_function

      SUBCOLUMNS = %w[Tokens Cost].freeze
      TOTAL_GROUP = "Total"

      # Token counts are abbreviated with scale suffixes (k/m/b) unless
      # verbose; costs are always shown in full. A trailing "Total" group sums
      # tokens and cost across every model for the (day, project) row.
      def render(rows, verbose: false, hide_project: false)
        models, keys, cells = Crosstab.pivot(rows)
        groups = models + [ TOTAL_GROUP ]

        labels = hide_project ? LABELS.take(1) : LABELS
        flat_headers = labels + groups.flat_map { SUBCOLUMNS }
        data = keys.map { |key| data_row(key, models, cells, verbose, hide_project) }
        total = totals_row(models, cells, verbose, hide_project)

        widths = widen_for_model_names(flat_widths(flat_headers, data + [ total ]), groups, labels.size)
        aligns = Array.new(labels.size, :left) + Array.new(groups.size * 2, :right)

        lines = [ top_header(groups, widths, labels.size), format_flat(flat_headers, widths, aligns), separator(widths) ]
        data.each { |row| lines << format_flat(row, widths, aligns) }
        lines << separator(widths)
        lines << format_flat(total, widths, aligns)
        "#{lines.join("\n")}\n"
      end

      def data_row(key, models, cells, verbose, hide_project)
        row = hide_project ? [ key.first ] : [ key.first, ProjectNormalizer.display(key.last) ]
        present = models.filter_map { |model| cells[key][model] }
        models.each do |model|
          cell = cells[key][model]
          row << (cell ? tokens(cell.usage.total, verbose) : "")
          row << (cell ? "$#{Formatters.delimit_decimal(cell.cost)}" : "")
        end
        row << tokens(present.sum(0) { |cell| cell.usage.total }, verbose)
        row << "$#{Formatters.delimit_decimal(present.sum(0.0, &:cost))}"
        row
      end

      def totals_row(models, cells, verbose, hide_project)
        row = hide_project ? [ "TOTAL" ] : [ "TOTAL", "" ]
        all = cells.values.flat_map(&:values)
        models.each do |model|
          present = cells.values.filter_map { |by_model| by_model[model] }
          row << tokens(present.sum(0) { |cell| cell.usage.total }, verbose)
          row << "$#{Formatters.delimit_decimal(present.sum(0.0, &:cost))}"
        end
        row << tokens(all.sum(0) { |cell| cell.usage.total }, verbose)
        row << "$#{Formatters.delimit_decimal(all.sum(0.0, &:cost))}"
        row
      end

      def tokens(value, verbose)
        verbose ? Formatters.delimit(value) : Formatters.scale(value)
      end

      def flat_widths(headers, rows)
        headers.each_index.map do |col|
          ([ headers[col].length ] + rows.map { |row| row[col].length }).max
        end
      end

      # Ensure each group's (Tokens, Cost) pair is at least as wide as the
      # heading that spans it (a model name, or "Total"), padding the Cost
      # column to absorb any deficit.
      def widen_for_model_names(widths, groups, label_count)
        widths = widths.dup
        groups.each_with_index do |group, index|
          tokens_col = label_count + (index * 2)
          cost_col = tokens_col + 1
          deficit = group.length - (widths[tokens_col] + GAP.length + widths[cost_col])
          widths[cost_col] += deficit if deficit.positive?
        end
        widths
      end

      def top_header(groups, widths, label_count)
        prefix_width = (0...label_count).sum { |col| widths[col] } + GAP.length * (label_count - 1)
        segments = [ " " * prefix_width ]
        groups.each_with_index do |group, index|
          tokens_col = label_count + (index * 2)
          span = widths[tokens_col] + GAP.length + widths[tokens_col + 1]
          segments << group.center(span)
        end
        segments.join(GAP).rstrip
      end

      def format_flat(values, widths, aligns)
        values.each_index.map do |col|
          aligns[col] == :left ? values[col].ljust(widths[col]) : values[col].rjust(widths[col])
        end.join(GAP).rstrip
      end

      def separator(widths)
        widths.map { |width| "-" * width }.join(GAP)
      end
    end

    # Machine-readable pivot: five model-prefixed columns per model. Cells with
    # no usage for a model are left blank.
    module Csv
      module_function

      METRICS = [ "Input", "Output", "Cache Write", "Cache Read", "Cost" ].freeze

      # verbose and hide_project are accepted for a uniform interface but
      # ignored — CSV always carries full-precision numbers and the project
      # column.
      def render(rows, verbose: false, hide_project: false)
        _ = verbose
        _ = hide_project
        models, keys, cells = Crosstab.pivot(rows)

        CSV.generate do |csv|
          csv << ([ "date", "project" ] + models.flat_map { |model| METRICS.map { |metric| "#{model} #{metric}" } })
          keys.each do |key|
            line = [ key.first, ProjectNormalizer.display(key.last) ]
            models.each { |model| line.concat(metric_values(cells[key][model])) }
            csv << line
          end
        end
      end

      def metric_values(cell)
        return Array.new(METRICS.size) unless cell

        usage = cell.usage
        [ usage.input, usage.output, usage.cache_write, usage.cache_read, format("%.4f", cell.cost) ]
      end
    end
  end
end
