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

      def render(rows)
        models, keys, cells = Crosstab.pivot(rows)

        flat_headers = LABELS + models.flat_map { SUBCOLUMNS }
        data = keys.map { |key| data_row(key, models, cells) }
        total = totals_row(models, cells)

        widths = widen_for_model_names(flat_widths(flat_headers, data + [ total ]), models)
        aligns = [ :left, :left ] + Array.new(models.size * 2, :right)

        lines = [ top_header(models, widths), format_flat(flat_headers, widths, aligns), separator(widths) ]
        data.each { |row| lines << format_flat(row, widths, aligns) }
        lines << separator(widths)
        lines << format_flat(total, widths, aligns)
        "#{lines.join("\n")}\n"
      end

      def data_row(key, models, cells)
        row = [ key.first, ProjectNormalizer.display(key.last) ]
        models.each do |model|
          cell = cells[key][model]
          row << (cell ? Formatters.delimit(cell.usage.total) : "")
          row << (cell ? "$#{Formatters.delimit_decimal(cell.cost)}" : "")
        end
        row
      end

      def totals_row(models, cells)
        row = [ "TOTAL", "" ]
        models.each do |model|
          present = cells.values.filter_map { |by_model| by_model[model] }
          row << Formatters.delimit(present.sum(0) { |cell| cell.usage.total })
          row << "$#{Formatters.delimit_decimal(present.sum(0.0, &:cost))}"
        end
        row
      end

      def flat_widths(headers, rows)
        headers.each_index.map do |col|
          ([ headers[col].length ] + rows.map { |row| row[col].length }).max
        end
      end

      # Ensure each model's (Tokens, Cost) pair is at least as wide as the model
      # name that spans it, padding the Cost column to absorb any deficit.
      def widen_for_model_names(widths, models)
        widths = widths.dup
        models.each_with_index do |model, index|
          tokens_col = 2 + (index * 2)
          cost_col = tokens_col + 1
          deficit = model.length - (widths[tokens_col] + GAP.length + widths[cost_col])
          widths[cost_col] += deficit if deficit.positive?
        end
        widths
      end

      def top_header(models, widths)
        segments = [ " " * (widths[0] + GAP.length + widths[1]) ]
        models.each_with_index do |model, index|
          tokens_col = 2 + (index * 2)
          span = widths[tokens_col] + GAP.length + widths[tokens_col + 1]
          segments << model.center(span)
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

      def render(rows)
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
