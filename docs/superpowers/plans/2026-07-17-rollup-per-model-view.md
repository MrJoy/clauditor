# `--rollup` Per-Model View Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `--rollup` view that collapses the per-day breakdown into one row per `(project, model)` — all-time or windowed by `--days`/`--since` — across table, csv, and json.

**Architecture:** A new `Clauditor::Rollup` module (parallel to `Clauditor::Crosstab`) owns both the collapse (group flat `Aggregator::Row`s by `(project, model)`, summing usage and already-computed per-row cost) and the three renderers. The CLI adds the flags, validates them, applies a date-window filter after `store.save`, and dispatches to `Rollup` when `--rollup` is set. `Config` gains mirror keys.

**Tech Stack:** Ruby 3.4.8, minitest, rubocop-rails-omakase (trailing commas required in multiline literals), `# frozen_string_literal: true` on every file.

## Global Constraints

- Every Ruby file starts with `# frozen_string_literal: true`.
- Multiline array/hash literals require trailing commas (rubocop override).
- Run `bundle exec rake lint:rubocop` before considering any task done; it must pass.
- Tests are minitest under `test/**/*_test.rb`; run with `bundle exec ruby -Itest <file>`.
- Cost is summed from each row's already-computed `cost` (nil-safe) — never re-derived from summed usage — so tiered pricing stays correct and unpriced models stay unpriced.
- Lexicographic string comparison of `"YYYY-MM-DD"` dates equals chronological order; the window filter relies on this.

---

### Task 1: `Rollup` module — collapse + Table renderer

**Files:**
- Create: `lib/clauditor/rollup.rb`
- Modify: `lib/clauditor.rb` (add require)
- Test: `test/clauditor/rollup_test.rb`

**Interfaces:**
- Consumes: `Aggregator::Row` (`project`, `date`, `model`, `usage`, `cost`, `priced?`), `Usage#+`, `Usage#total`, `Formatters.delimit`, `Formatters.delimit_decimal`, `ProjectNormalizer.display`.
- Produces:
  - `Rollup.for(name)` → returns `Rollup::Table` for `"table"`, raises `ArgumentError` for unknown (Csv/Json added in Task 2).
  - `Rollup.collapse(rows)` → `Array<Aggregator::Row>`, one per `(project, model)`, `date: nil`, usage summed, cost summed (nil only when no component priced), sorted by `[project, model]`.
  - `Rollup::Table.render(rows, hide_project: false)` → `String`.

- [ ] **Step 1: Write the failing test**

Create `test/clauditor/rollup_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"
require "csv"

module Clauditor
  class RollupTest < Minitest::Test
    def row(project:, date:, model:, input:, cost:)
      Aggregator::Row.new(
        project: project,
        date: date,
        model: model,
        usage: Usage.new(input: input, output: 2, cache_read: 3, cache_write_5m: 4, cache_write_1h: 0),
        cost: cost,
      )
    end

    def test_collapse_sums_usage_and_cost_across_dates
      rows = [
        row(project: "/Users/me/a", date: "2026-06-07", model: "opus-4-8", input: 100, cost: 1.5),
        row(project: "/Users/me/a", date: "2026-06-08", model: "opus-4-8", input: 50, cost: 0.9),
      ]

      cells = Rollup.collapse(rows)

      assert_equal 1, cells.size
      assert_nil cells.first.date
      assert_equal 150, cells.first.usage.input
      assert_in_delta 2.4, cells.first.cost, 1e-9
    end

    def test_collapse_groups_by_project_and_model_sorted
      rows = [
        row(project: "/Users/me/b", date: "2026-06-07", model: "opus-4-8", input: 1, cost: 0.1),
        row(project: "/Users/me/a", date: "2026-06-07", model: "sonnet-5", input: 1, cost: 0.1),
        row(project: "/Users/me/a", date: "2026-06-07", model: "opus-4-8", input: 1, cost: 0.1),
      ]

      keys = Rollup.collapse(rows).map { |r| [ r.project, r.model ] }

      assert_equal [
        [ "/Users/me/a", "opus-4-8" ],
        [ "/Users/me/a", "sonnet-5" ],
        [ "/Users/me/b", "opus-4-8" ],
      ], keys
    end

    def test_collapse_unpriced_only_when_no_component_priced
      rows = [
        row(project: "/Users/me/a", date: "2026-06-07", model: "qwen", input: 5, cost: nil),
        row(project: "/Users/me/a", date: "2026-06-08", model: "qwen", input: 7, cost: nil),
      ]

      cell = Rollup.collapse(rows).first

      assert_nil cell.cost
      refute cell.priced?
    end

    def test_table_renders_project_model_and_totals
      rows = [
        row(project: "/Users/me/a", date: "2026-06-07", model: "opus-4-8", input: 100, cost: 1.5),
        row(project: "/Users/me/a", date: "2026-06-08", model: "opus-4-8", input: 50, cost: 0.9),
      ]

      lines = Rollup::Table.render(rows).lines

      assert_includes lines[0], "Project"
      assert_includes lines[0], "Model"
      refute_includes lines[0], "Date"
      data = lines.find { |l| l.include?("opus-4-8") && !l.start_with?("TOTAL") }
      assert_includes data, "150"
      total = lines.find { |l| l.start_with?("TOTAL") }
      assert_includes total, "$2.40"
    end

    def test_table_drops_project_column_when_hidden
      rows = [ row(project: "/Users/me/a", date: "2026-06-07", model: "opus-4-8", input: 100, cost: 1.5) ]

      lines = Rollup::Table.render(rows, hide_project: true).lines

      refute_includes lines[0], "Project"
      assert lines[0].start_with?("Model"), "Model should lead the header"
      refute(lines.any? { |line| line.include?("/Users/me/a") })
      assert(lines.any? { |line| line.start_with?("TOTAL") })
    end

    def test_table_unpriced_cost_renders_dash
      rows = [ row(project: "/Users/me/a", date: "2026-06-07", model: "qwen", input: 5, cost: nil) ]

      data = Rollup::Table.render(rows).lines.find { |l| l.include?("qwen") }

      assert_includes data, "—"
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec ruby -Itest test/clauditor/rollup_test.rb`
Expected: FAIL — `uninitialized constant Clauditor::Rollup`.

- [ ] **Step 3: Write minimal implementation**

Create `lib/clauditor/rollup.rb`:

```ruby
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

      HEADERS = [ "Project", "Model", "Input", "Output", "Cache Write", "Cache Read", "Cost" ].freeze

      # hide_project drops the leading Project column (single-project output).
      def render(rows, hide_project: false)
        cells = Rollup.collapse(rows)
        headers = hide_project ? HEADERS.drop(1) : HEADERS
        table = cells.map { |cell| columns(cell, hide_project) }
        table << totals_row(cells, hide_project)
        label_cols = hide_project ? 1 : 2

        widths = column_widths(headers, table)
        lines = []
        lines << format_row(headers, widths, label_cols)
        lines << separator(widths)
        table.each_with_index do |cols, index|
          lines << separator(widths) if index == table.size - 1
          lines << format_row(cols, widths, label_cols)
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
          cost_cell(row.cost),
        ]
      end

      def totals_row(cells, hide_project)
        usage = cells.map(&:usage).reduce(Usage.new, :+)
        priced = cells.select(&:priced?).sum(&:cost)
        labels = hide_project ? [ "TOTAL" ] : [ "TOTAL", "" ]
        labels + [
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

      def column_widths(headers, table)
        headers.each_index.map do |col|
          ([ headers[col].length ] + table.map { |cols| cols[col].length }).max
        end
      end

      def format_row(cols, widths, label_cols)
        cols.each_with_index.map do |value, col|
          col < label_cols ? value.ljust(widths[col]) : value.rjust(widths[col])
        end.join("  ").rstrip
      end

      def separator(widths)
        widths.map { |w| "-" * w }.join("  ")
      end
    end
  end
end
```

Add the require to `lib/clauditor.rb`, immediately after the `crosstab` line:

```ruby
require_relative "clauditor/crosstab"
require_relative "clauditor/rollup"
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec ruby -Itest test/clauditor/rollup_test.rb`
Expected: PASS (6 tests).

- [ ] **Step 5: Lint**

Run: `bundle exec rake lint:rubocop`
Expected: no offenses.

- [ ] **Step 6: Commit**

```bash
git add lib/clauditor/rollup.rb lib/clauditor.rb test/clauditor/rollup_test.rb
git commit -m "Add Rollup collapse and table renderer"
```

---

### Task 2: `Rollup` Csv + Json renderers

**Files:**
- Modify: `lib/clauditor/rollup.rb`
- Test: `test/clauditor/rollup_test.rb`

**Interfaces:**
- Consumes: `Rollup.collapse` (Task 1), `Usage#total`.
- Produces:
  - `Rollup::Csv.render(rows, hide_project: false)` → CSV string, header `project,model,input_tokens,output_tokens,cache_creation_tokens,cache_read_tokens,total_tokens,cost_usd`; cost blank for unpriced. `hide_project` accepted but ignored.
  - `Rollup::Json.render(rows, hide_project: false)` → pretty JSON array of `{project, model, input_tokens, output_tokens, cache_creation_tokens, cache_read_tokens, total_tokens, cost_usd, priced}`; `cost_usd` null and `priced:false` for unpriced. `hide_project` accepted but ignored.
  - `Rollup.for` now also returns `Csv` for `"csv"` and `Json` for `"json"`.

- [ ] **Step 1: Write the failing test**

Append these methods inside `class RollupTest` in `test/clauditor/rollup_test.rb`:

```ruby
    def test_csv_has_project_model_and_no_date_column
      rows = [
        row(project: "/Users/me/a", date: "2026-06-07", model: "opus-4-8", input: 100, cost: 1.5),
        row(project: "/Users/me/a", date: "2026-06-08", model: "opus-4-8", input: 50, cost: 0.9),
      ]

      table = CSV.parse(Rollup::Csv.render(rows), headers: true)

      assert_equal %w[project model input_tokens output_tokens cache_creation_tokens cache_read_tokens total_tokens cost_usd], table.headers
      refute_includes table.headers, "date"
      assert_equal 1, table.size
      assert_equal "150", table.first["input_tokens"]
      assert_equal "2.4000", table.first["cost_usd"]
    end

    def test_csv_blanks_cost_for_unpriced_model
      rows = [ row(project: "/Users/me/a", date: "2026-06-07", model: "qwen", input: 5, cost: nil) ]

      table = CSV.parse(Rollup::Csv.render(rows), headers: true)

      assert_nil table.first["cost_usd"]
    end

    def test_json_collapses_to_per_project_model
      rows = [
        row(project: "/Users/me/a", date: "2026-06-07", model: "opus-4-8", input: 100, cost: 1.5),
        row(project: "/Users/me/a", date: "2026-06-08", model: "opus-4-8", input: 50, cost: 0.9),
      ]

      payload = JSON.parse(Rollup::Json.render(rows))

      assert_equal 1, payload.size
      refute payload.first.key?("date")
      assert_equal 150, payload.first["input_tokens"]
      assert_in_delta 2.4, payload.first["cost_usd"], 1e-9
      assert_equal true, payload.first["priced"]
    end

    def test_json_marks_unpriced_model
      rows = [ row(project: "/Users/me/a", date: "2026-06-07", model: "qwen", input: 5, cost: nil) ]

      payload = JSON.parse(Rollup::Json.render(rows))

      assert_nil payload.first["cost_usd"]
      assert_equal false, payload.first["priced"]
    end

    def test_for_dispatches_by_format_name
      assert_equal Rollup::Table, Rollup.for("table")
      assert_equal Rollup::Csv, Rollup.for("csv")
      assert_equal Rollup::Json, Rollup.for("json")
      assert_raises(ArgumentError) { Rollup.for("xml") }
    end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec ruby -Itest test/clauditor/rollup_test.rb`
Expected: FAIL — `uninitialized constant Clauditor::Rollup::Csv` (and `Json`).

- [ ] **Step 3: Write minimal implementation**

In `lib/clauditor/rollup.rb`, extend the `for` dispatch to include the new formats:

```ruby
    def for(name)
      case name.to_s
      when "table" then Table
      when "csv" then Csv
      when "json" then Json
      else
        raise ArgumentError, "unknown format: #{name}"
      end
    end
```

Then add these two modules inside `module Rollup`, after `module Table ... end`:

```ruby
    # Machine-readable rows; cost left blank for unpriced models.
    module Csv
      module_function

      # hide_project is accepted for a uniform interface but ignored.
      def render(rows, hide_project: false)
        _ = hide_project
        CSV.generate do |csv|
          csv << [
            "project", "model",
            "input_tokens", "output_tokens",
            "cache_creation_tokens", "cache_read_tokens",
            "total_tokens", "cost_usd"
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

      # hide_project is accepted for a uniform interface but ignored.
      def render(rows, hide_project: false)
        _ = hide_project
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec ruby -Itest test/clauditor/rollup_test.rb`
Expected: PASS (11 tests total).

- [ ] **Step 5: Lint**

Run: `bundle exec rake lint:rubocop`
Expected: no offenses.

- [ ] **Step 6: Commit**

```bash
git add lib/clauditor/rollup.rb test/clauditor/rollup_test.rb
git commit -m "Add Rollup csv and json renderers"
```

---

### Task 3: CLI integration — flags, validation, window filter, dispatch

**Files:**
- Modify: `lib/clauditor/cli.rb`
- Test: `test/clauditor/cli_test.rb`

**Interfaces:**
- Consumes: `Rollup.for` (Tasks 1–2), existing `filter_projects`, `Aggregator`, `Store`, `SessionLoader`.
- Produces (option symbols the CLI assembles, consumed by Config in Task 4): `options[:rollup]` (bool), `options[:days]` (Integer or nil), `options[:since]` (String `"YYYY-MM-DD"` or nil). New validation method `validate_rollup_options!(options)` and window helpers `window_rows` / `days_cutoff`.

- [ ] **Step 1: Write the failing tests**

Append these methods inside `class CLITest` in `test/clauditor/cli_test.rb`:

```ruby
    def test_rollup_table_collapses_dates
      Dir.mktmpdir do |root|
        File.write(File.join(root, "s.jsonl"), <<~JSONL)
          {"type":"assistant","cwd":"/Users/me/proj","timestamp":"2026-06-07T12:00:00.000Z","message":{"id":"m1","model":"claude-opus-4-8","usage":{"input_tokens":100,"output_tokens":10}}}
          {"type":"assistant","cwd":"/Users/me/proj","timestamp":"2026-06-08T12:00:00.000Z","message":{"id":"m2","model":"claude-opus-4-8","usage":{"input_tokens":50,"output_tokens":5}}}
        JSONL
        status, out, = run_cli([ "--root", root, "--utc", "--rollup" ])

        assert_equal 0, status
        assert_includes out, "Model"
        refute_includes out, "Date"
        assert_includes out, "150"
        data = out.lines.select { |l| l.include?("opus-4-8") }
        assert_equal 1, data.size
      end
    end

    def test_rollup_json_collapses_dates
      Dir.mktmpdir do |root|
        File.write(File.join(root, "s.jsonl"), <<~JSONL)
          {"type":"assistant","cwd":"/Users/me/proj","timestamp":"2026-06-07T12:00:00.000Z","message":{"id":"m1","model":"claude-opus-4-8","usage":{"input_tokens":100,"output_tokens":10}}}
          {"type":"assistant","cwd":"/Users/me/proj","timestamp":"2026-06-08T12:00:00.000Z","message":{"id":"m2","model":"claude-opus-4-8","usage":{"input_tokens":50,"output_tokens":5}}}
        JSONL
        status, out, = run_cli([ "--root", root, "--utc", "--rollup", "--format", "json" ])
        payload = JSON.parse(out)

        assert_equal 0, status
        assert_equal 1, payload.size
        assert_equal 150, payload.first["input_tokens"]
        refute payload.first.key?("date")
      end
    end

    def test_rollup_days_window_excludes_older_rows
      Dir.mktmpdir do |root|
        recent = Time.now.utc.strftime("%Y-%m-%dT%H:%M:%S.000Z")
        File.write(File.join(root, "s.jsonl"), <<~JSONL)
          {"type":"assistant","cwd":"/Users/me/proj","timestamp":"2000-01-01T12:00:00.000Z","message":{"id":"old","model":"claude-opus-4-8","usage":{"input_tokens":999,"output_tokens":1}}}
          {"type":"assistant","cwd":"/Users/me/proj","timestamp":"#{recent}","message":{"id":"new","model":"claude-opus-4-8","usage":{"input_tokens":42,"output_tokens":1}}}
        JSONL
        status, out, = run_cli([ "--root", root, "--utc", "--rollup", "--days", "1" ])

        assert_equal 0, status
        assert_includes out, "42"
        refute_includes out, "999"
      end
    end

    def test_rollup_since_window_excludes_older_rows
      Dir.mktmpdir do |root|
        File.write(File.join(root, "s.jsonl"), <<~JSONL)
          {"type":"assistant","cwd":"/Users/me/proj","timestamp":"2026-06-01T12:00:00.000Z","message":{"id":"a","model":"claude-opus-4-8","usage":{"input_tokens":11,"output_tokens":1}}}
          {"type":"assistant","cwd":"/Users/me/proj","timestamp":"2026-06-10T12:00:00.000Z","message":{"id":"b","model":"claude-opus-4-8","usage":{"input_tokens":22,"output_tokens":1}}}
        JSONL
        status, out, = run_cli([ "--root", root, "--utc", "--rollup", "--since", "2026-06-05" ])

        assert_equal 0, status
        assert_includes out, "22"
        refute_includes out, "11"
      end
    end

    def test_rollup_with_anthropic_errors
      status, _out, err = run_cli([ "--rollup", "--anthropic" ])

      assert_equal 1, status
      assert_includes err, "--rollup and --anthropic cannot be combined"
    end

    def test_days_and_since_together_error
      status, _out, err = run_cli([ "--rollup", "--days", "7", "--since", "2026-06-01" ])

      assert_equal 1, status
      assert_includes err, "--days and --since cannot be combined"
    end

    def test_days_without_rollup_errors
      status, _out, err = run_cli([ "--days", "7" ])

      assert_equal 1, status
      assert_includes err, "--days requires --rollup"
    end

    def test_since_without_rollup_errors
      status, _out, err = run_cli([ "--since", "2026-06-01" ])

      assert_equal 1, status
      assert_includes err, "--since requires --rollup"
    end

    def test_days_non_positive_errors
      status, _out, err = run_cli([ "--rollup", "--days", "0" ])

      assert_equal 1, status
      assert_includes err, "--days must be a positive integer"
    end

    def test_invalid_since_date_errors
      status, _out, err = run_cli([ "--rollup", "--since", "nope" ])

      assert_equal 1, status
      assert_includes err, "invalid --since date"
    end

    def test_rollup_single_project_hides_project_column
      Dir.mktmpdir do |root|
        File.write(File.join(root, "s.jsonl"), <<~JSONL)
          {"type":"assistant","cwd":"/Users/me/proj","timestamp":"2026-06-07T12:00:00.000Z","message":{"id":"m1","model":"claude-opus-4-8","usage":{"input_tokens":100,"output_tokens":10}}}
        JSONL
        status, out, = run_cli([ "--root", root, "--utc", "--rollup", "--project", "proj" ])

        assert_equal 0, status
        refute_includes out, "Project"
        assert out.lines.first.start_with?("Model"), "Model should lead when project hidden"
      end
    end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec ruby -Itest test/clauditor/cli_test.rb`
Expected: FAIL — `--rollup` is an invalid option (`OptionParser::InvalidOption`), so the rollup runs error out and the collapse tests don't see collapsed output.

- [ ] **Step 3: Write minimal implementation**

In `lib/clauditor/cli.rb`, add `require "date"` at the top, after `require "optparse"`:

```ruby
require "optparse"
require "date"
```

Add the three defaults to the options hash in `parse` (alongside `anthropic`, `summary`, etc.):

```ruby
        anthropic: false,
        summary: false,
        rollup: false,
        days: nil,
        since: nil,
        verbose: false,
```

Add the three flags to the `OptionParser` block, after the `--summary` flag:

```ruby
        opts.on("--rollup", "Collapse dates: totals per (project, model) across the window") do
          options[:rollup] = true
        end

        opts.on("--days N", Integer, "With --rollup: only the last N days, including today") do |n|
          options[:days] = n
        end

        opts.on("--since DATE", "With --rollup: only rows dated on or after DATE (YYYY-MM-DD)") do |date|
          options[:since] = date
        end
```

In `run`, add the validation call immediately after `return 0 if options[:exit]`:

```ruby
      return 0 if options[:exit]

      validate_rollup_options!(options)
```

In `run`, replace the block from `rows = filter_projects(...)` down through the render `if/else` with:

```ruby
      rows = filter_projects(rows, options[:project])
      rows = window_rows(rows, days: options[:days], since: options[:since], timezone: options[:timezone]) if options[:rollup]

      # When a --project filter has narrowed the output to a single project the
      # project column is redundant; drop it from the human-readable views
      # (CSV/JSON keep it, and ignore the flag).
      hide_project = !options[:project].nil? && rows.map(&:project).uniq.size == 1

      if options[:rollup]
        out.print Rollup.for(options[:format]).render(rows, hide_project: hide_project)
      elsif options[:anthropic]
        out.print Crosstab.for(options[:format]).render(
          rows,
          verbose: options[:verbose],
          hide_project: hide_project,
          summary: options[:summary],
        )
      else
        out.print Formatters.for(options[:format]).render(rows, hide_project: hide_project)
      end
      0
```

Add these private methods to `CLI` (e.g. right after `filter_projects`):

```ruby
    # --rollup-only flags: mutually exclusive with --anthropic and with each
    # other, and inert without --rollup (so we reject them rather than let them
    # silently do nothing).
    def validate_rollup_options!(options)
      raise ArgumentError, "--rollup and --anthropic cannot be combined" if options[:rollup] && options[:anthropic]
      raise ArgumentError, "--days and --since cannot be combined" if options[:days] && options[:since]

      unless options[:rollup]
        raise ArgumentError, "--days requires --rollup" if options[:days]
        raise ArgumentError, "--since requires --rollup" if options[:since]
        return
      end

      raise ArgumentError, "--days must be a positive integer" if options[:days] && options[:days] < 1
      validate_since!(options[:since]) if options[:since]
    end

    def validate_since!(value)
      Date.strptime(value, "%Y-%m-%d")
    rescue ArgumentError
      raise ArgumentError, "invalid --since date '#{value}' (expected YYYY-MM-DD)"
    end

    # Keeps only rows within the window. Rows dated "unknown" can't be placed on
    # the timeline, so they're dropped whenever a window is active. Date strings
    # compare lexicographically the same as chronologically.
    def window_rows(rows, days:, since:, timezone:)
      cutoff = since || days_cutoff(days, timezone)
      return rows if cutoff.nil?

      rows.select { |row| row.date != "unknown" && row.date >= cutoff }
    end

    # The inclusive lower-bound day for --days N: N calendar days back including
    # today, in the active timezone (matching how the aggregator buckets days).
    def days_cutoff(days, timezone)
      return nil if days.nil?

      today = timezone == :utc ? Time.now.utc.to_date : Date.today
      (today - (days - 1)).to_s
    end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec ruby -Itest test/clauditor/cli_test.rb`
Expected: PASS (all existing plus the 11 new tests).

- [ ] **Step 5: Lint**

Run: `bundle exec rake lint:rubocop`
Expected: no offenses.

- [ ] **Step 6: Commit**

```bash
git add lib/clauditor/cli.rb test/clauditor/cli_test.rb
git commit -m "Wire --rollup, --days, and --since into the CLI"
```

---

### Task 4: Config mirror keys (`rollup`, `days`, `since`)

**Files:**
- Modify: `lib/clauditor/config.rb`
- Test: `test/clauditor/config_test.rb`, `test/clauditor/cli_test.rb`

**Interfaces:**
- Consumes: existing `Config.boolean`, the `translate` dispatch, and the option symbols from Task 3 (`:rollup`, `:days`, `:since`).
- Produces: config keys `rollup` (boolean → `:rollup`), `days` (Integer → `:days`), `since` (string → `:since`). New helper `Config.integer(value, key, path)`. Cross-flag validation is unchanged — it stays in `CLI#validate_rollup_options!`, which runs on the merged option set and therefore also guards config-sourced values.

- [ ] **Step 1: Write the failing tests**

Append to `class ConfigTest` in `test/clauditor/config_test.rb`:

```ruby
    def test_translates_rollup_days_since
      with_config("rollup: true\ndays: 5\nsince: \"2026-06-01\"\n") do |path|
        options = Config.load(path: path)

        assert_equal true, options[:rollup]
        assert_equal 5, options[:days]
        assert_equal "2026-06-01", options[:since]
      end
    end

    def test_rollup_must_be_boolean
      with_config("rollup: sometimes\n") do |path|
        error = assert_raises(ArgumentError) { Config.load(path: path) }
        assert_includes error.message, "true or false"
      end
    end

    def test_days_must_be_integer
      with_config("days: soon\n") do |path|
        error = assert_raises(ArgumentError) { Config.load(path: path) }
        assert_includes error.message, "must be an integer"
      end
    end
```

Append to `class CLITest` in `test/clauditor/cli_test.rb` (verifies the merged-option validation guards config-sourced values too):

```ruby
    def test_config_days_without_rollup_errors
      with_config("days: 7\n") do |config_path|
        status, _out, err = run_cli([], config_path: config_path)

        assert_equal 1, status
        assert_includes err, "--days requires --rollup"
      end
    end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec ruby -Itest test/clauditor/config_test.rb`
Expected: FAIL — `unknown option 'rollup'` (Config rejects the new keys).

- [ ] **Step 3: Write minimal implementation**

In `lib/clauditor/config.rb`, add three `when` branches to `translate`, after the `summary` branch:

```ruby
        when "summary"
          options[:summary] = boolean(value, "summary", path)
        when "rollup"
          options[:rollup] = boolean(value, "rollup", path)
        when "days"
          options[:days] = integer(value, "days", path)
        when "since"
          options[:since] = value.to_s
```

Add the `integer` helper alongside `boolean`:

```ruby
    def self.integer(value, key, path)
      return value if value.is_a?(Integer)

      raise ArgumentError, "#{path}: '#{key}' must be an integer"
    end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec ruby -Itest test/clauditor/config_test.rb && bundle exec ruby -Itest test/clauditor/cli_test.rb`
Expected: PASS.

- [ ] **Step 5: Lint**

Run: `bundle exec rake lint:rubocop`
Expected: no offenses.

- [ ] **Step 6: Commit**

```bash
git add lib/clauditor/config.rb test/clauditor/config_test.rb test/clauditor/cli_test.rb
git commit -m "Add rollup/days/since config mirror keys"
```

---

### Task 5: Documentation + full-suite green

**Files:**
- Modify: `README.md`, `CHANGELOG.md`, `CLAUDE.md`

**Interfaces:** none (docs only). This task ships no behavior; it documents Tasks 1–4 and confirms the whole suite is green.

- [ ] **Step 1: Update README options table**

In `README.md`, add these rows to the Options table (after the `--summary`/`--verbose` rows, before `--project`):

```markdown
| `--rollup` | Collapse the per-day breakdown into one row per `(project, model)`, summed across the window. Works with `table`, `csv`, and `json`. Cannot be combined with `--anthropic`. |
| `--days N` | With `--rollup`: keep only the last `N` days, **including today**, in the active timezone. Rollup-only; error otherwise. Mutually exclusive with `--since`. |
| `--since DATE` | With `--rollup`: keep only rows dated on or after `DATE` (`YYYY-MM-DD`). Rollup-only; error otherwise. Mutually exclusive with `--days`. |
```

- [ ] **Step 2: Add a README section and example**

In `README.md`, add a subsection after "The `--anthropic` crosstab":

```markdown
### The `--rollup` view

`--rollup` collapses the date dimension: instead of a line per `(project, day, model)`, you get one
line per `(project, model)` with usage and cost summed across the whole window, sorted by project
then model. It works in `table`, `csv`, and `json`. Costs are summed from each day's already-priced
figure, so a model whose list price changed mid-window still totals correctly.

Restrict the window with `--days N` (the last `N` days including today) or `--since YYYY-MM-DD` (an
absolute cutoff). Both are rollup-only and mutually exclusive. `--rollup` cannot be combined with
`--anthropic`.
```

Add to the Examples block:

```markdown
# All-time totals per project and model
bundle exec bin/clauditor --rollup

# Last 30 days, one project, as JSON
bundle exec bin/clauditor --rollup --days 30 --project ~/mrjoy/clauditor --format json
```

- [ ] **Step 3: Update the README config example**

In `README.md`, add these keys to the `~/.clauditor_config` YAML block, after the `verbose:` line:

```yaml
rollup: false                  # collapse dates to per-(project, model) totals
days: 30                       # with rollup: only the last N days (mutually exclusive with since)
since: 2026-01-01              # with rollup: only rows on/after this date (mutually exclusive with days)
```

- [ ] **Step 4: Update CHANGELOG**

In `CHANGELOG.md`, under `## [Unreleased]`, add:

```markdown
## [Unreleased]

### Added

- `--rollup` collapses the per-day breakdown into per-`(project, model)` totals across all output formats. `--days N` and `--since DATE` restrict the window (rollup-only, mutually exclusive). Mirror keys (`rollup`, `days`, `since`) are available in the config file.
```

- [ ] **Step 5: Update CLAUDE.md**

In `CLAUDE.md`, update the usage line at the top ("Run it via …") to include the new flags:

```markdown
`bundle exec bin/clauditor [--format table|csv|json] [--anthropic] [--summary] [--rollup] [--days N] [--since YYYY-MM-DD] [--verbose] [--project NAME] [--utc] [--root DIR ...] [--no-store] [--store-dir DIR]`.
```

And add a sentence to the **`Formatters`** or a new bullet describing `Rollup`, after the `Crosstab` bullet in the Architecture section:

```markdown
- **`Rollup`** is the `--rollup` view: it collapses each `(project, model)` across the date dimension into a single all-time (or windowed) total, summing usage and the already-computed per-row cost (so tiered pricing stays correct), and renders in table/csv/json via `Rollup.for(format)`. The window is set by `--days N` (last N days incl. today, timezone-aware) or `--since YYYY-MM-DD` — both rollup-only and mutually exclusive, and `--rollup` conflicts with `--anthropic`. The CLI applies the window filter after `Store#save` so the persisted dataset stays complete. `Config` mirrors `rollup`/`days`/`since`.
```

- [ ] **Step 6: Run the full suite and lint**

Run: `bundle exec rake test && bundle exec rake lint`
Expected: all tests pass; rubocop and bundler-audit clean.

- [ ] **Step 7: Commit**

```bash
git add README.md CHANGELOG.md CLAUDE.md
git commit -m "Document the --rollup view"
```

---

## Self-Review

**Spec coverage:**
- `--rollup` per `(project, model)`, date collapsed, sorted project-then-model → Tasks 1–3. ✓
- Works in table/csv/json → Tasks 1–2, dispatch in Task 3. ✓
- `--days N` (incl. today, tz-aware) and `--since DATE` → Task 3 (`window_rows`/`days_cutoff`). ✓
- Rollup-only + mutual-exclusion + `--rollup`/`--anthropic` conflict, all hard errors → Task 3 (`validate_rollup_options!`). ✓
- Project column dropped only when narrowed to a single project → Task 3 (reuses existing `hide_project` rule; test `test_rollup_single_project_hides_project_column`). ✓
- Cost summed from precomputed per-row costs (tiered pricing safe); unpriced handling → Task 1 (`collapse`) + tests. ✓
- `unknown`-dated rows dropped when a window is active → Task 3 (`window_rows`). ✓
- Store still persists the complete dataset (window filter is post-`save`) → Task 3 leaves `store&.save(rows)` before filtering. ✓
- Config mirrors `rollup`/`days`/`since` with validation → Task 4. ✓
- Docs (README/CHANGELOG/CLAUDE.md) → Task 5. ✓

**Placeholder scan:** No TBD/TODO/"handle edge cases"; every code and test step shows complete content. ✓

**Type consistency:** `Rollup.for`, `Rollup.collapse`, `Rollup::Table/Csv/Json.render(rows, hide_project:)`, `validate_rollup_options!`, `window_rows(rows, days:, since:, timezone:)`, `days_cutoff(days, timezone)`, `Config.integer(value, key, path)` — names and signatures are consistent across the tasks that define and call them. `Aggregator::Row` fields (`project`, `date`, `model`, `usage`, `cost`, `priced?`) match usage. ✓

**Note on validation placement (spec refinement):** The spec suggested `Config` type-checks and the CLI does cross-flag checks. This plan centralizes *all* semantic checks (positivity, date-format, mutual-exclusion, requires-rollup) in `CLI#validate_rollup_options!`, which runs on the merged options and so guards both config- and CLI-sourced values in one place (DRY). `Config` only type-checks (`boolean`/`integer`). User-facing behavior is identical: every rejection is an `ArgumentError` the CLI prints as `clauditor: …` with exit 1 — verified for config by `test_config_days_without_rollup_errors`.
