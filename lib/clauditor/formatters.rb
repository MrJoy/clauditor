# frozen_string_literal: true

require "csv"
require "json"

module Clauditor
  # Renders aggregated rows in the user-selectable output formats.
  module Formatters
    module_function

    # Thousands-separated integer, e.g. 1234567 => "1,234,567".
    def delimit(number)
      number.to_i.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\1,').reverse
    end

    # Compact magnitude with a scale suffix, e.g. 1234567 => "1.2m". Values
    # below 1,000 are left as plain integers.
    def scale(number)
      number = number.to_i
      abs = number.abs
      if abs >= 1_000_000_000
        "#{format("%.1f", number / 1_000_000_000.0)}b"
      elsif abs >= 1_000_000
        "#{format("%.1f", number / 1_000_000.0)}m"
      elsif abs >= 1_000
        "#{format("%.1f", number / 1_000.0)}k"
      else
        number.to_s
      end
    end

    # Renders a dollar figure with thousands separators and two decimals.
    def delimit_decimal(cost)
      whole, fraction = format("%.2f", cost).split(".")
      "#{delimit(whole)}.#{fraction}"
    end

    def for(name)
      case name.to_s
      when "table" then Table
      when "csv" then Csv
      when "json" then Json
      else
        raise ArgumentError, "unknown format: #{name}"
      end
    end

    # Aligned, human-readable columns with a totals row.
    module Table
      module_function

      HEADERS = [ "Project", "Date", "Model", "Input", "Output", "Cache Write", "Cache Read", "Cost" ].freeze

      def render(rows)
        table = rows.map { |row| columns(row) }
        table << totals_row(rows)

        widths = column_widths(table)
        lines = []
        lines << format_row(HEADERS, widths)
        lines << separator(widths)
        table.each_with_index do |cols, index|
          lines << separator(widths) if index == table.size - 1
          lines << format_row(cols, widths)
        end
        "#{lines.join("\n")}\n"
      end

      def columns(row)
        [
          ProjectNormalizer.display(row.project),
          row.date,
          row.model,
          Formatters.delimit(row.usage.input),
          Formatters.delimit(row.usage.output),
          Formatters.delimit(row.usage.cache_write),
          Formatters.delimit(row.usage.cache_read),
          cost_cell(row.cost),
        ]
      end

      def totals_row(rows)
        usage = rows.map(&:usage).reduce(Usage.new, :+)
        priced = rows.select(&:priced?).sum(&:cost)
        [
          "TOTAL",
          "",
          "",
          Formatters.delimit(usage.input),
          Formatters.delimit(usage.output),
          Formatters.delimit(usage.cache_write),
          Formatters.delimit(usage.cache_read),
          cost_cell(priced),
        ]
      end

      def cost_cell(cost)
        cost.nil? ? "—" : "$#{Formatters.delimit_decimal(cost)}"
      end

      def column_widths(table)
        HEADERS.each_index.map do |col|
          ([ HEADERS[col].length ] + table.map { |cols| cols[col].length }).max
        end
      end

      # Project, Date, Model left-aligned; numeric columns right-aligned.
      def format_row(cols, widths)
        cols.each_with_index.map do |value, col|
          col < 3 ? value.ljust(widths[col]) : value.rjust(widths[col])
        end.join("  ").rstrip
      end

      def separator(widths)
        widths.map { |w| "-" * w }.join("  ")
      end
    end

    # Machine-readable rows; cost left blank for unpriced models.
    module Csv
      module_function

      def render(rows)
        CSV.generate do |csv|
          csv << [
            "project", "date", "model",
            "input_tokens", "output_tokens",
            "cache_creation_tokens", "cache_read_tokens",
            "total_tokens", "cost_usd"
          ]
          rows.each do |row|
            csv << [
              ProjectNormalizer.display(row.project),
              row.date,
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

      def render(rows)
        payload = rows.map do |row|
          {
            project: ProjectNormalizer.display(row.project),
            date: row.date,
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
