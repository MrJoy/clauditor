# `--model` Prefix Filter Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `--model NAME` option that filters report rows to models whose id begins with `NAME` (case-insensitive prefix), eliding the redundant model dimension from the human-readable views when a single model remains.

**Architecture:** Mirror the existing `--project` filter. A `filter_models` step in `CLI` narrows rows; a `hide_model` flag (computed exactly like `hide_project`) is threaded into every renderer. Table views drop the model label column (flat/rollup) or the redundant Total group (crosstab); CSV/JSON accept the flag and ignore it. A `model` config key mirrors the flag.

**Tech Stack:** Ruby 3.4, minitest, rubocop-rails-omakase.

## Global Constraints

- Every Ruby file starts with `# frozen_string_literal: true`.
- Style is rubocop-rails-omakase with **trailing commas required in multiline array/hash literals**. Run `bundle exec rake lint:rubocop` before considering any task done.
- Tests are minitest, discovered as `test/**/*_test.rb`. Run the full suite with `bundle exec rake test`; a single file with `bundle exec ruby -Itest test/clauditor/foo_test.rb`.
- `row.model` is the already-normalized/displayed model id (e.g. `opus-4-8`); filter and match against it directly.
- `hide_model` is gated on the flag being set: `!options[:model].nil? && rows.map(&:model).uniq.size == 1`.

---

### Task 1: Flat `Formatters::Table` model-column elision

Make the flat table drop the `Model` label column when `hide_model` is set, composing with the existing `hide_project`. `Csv`/`Json` accept the new keyword and ignore it.

**Files:**
- Modify: `lib/clauditor/formatters.rb`
- Test: `test/clauditor/formatters_test.rb`

**Interfaces:**
- Produces: `Formatters::Table.render(rows, hide_project: false, hide_model: false)`, `Formatters::Csv.render(rows, hide_project: false, hide_model: false)`, `Formatters::Json.render(rows, hide_project: false, hide_model: false)`.

- [ ] **Step 1: Write the failing tests**

Add to `test/clauditor/formatters_test.rb` (the existing `rows` helper yields an `opus-4-8` row and a `qwen…` row):

```ruby
def test_table_drops_model_column_when_hidden
  output = Formatters::Table.render(rows, hide_model: true)
  header = output.lines.first

  refute_includes header, "Model"
  assert_includes header, "Project"
  assert_includes header, "Date"
  refute_includes output, "opus-4-8"
  assert_includes output, "TOTAL"
  assert_includes output, "$1,234.57"
end

def test_table_drops_both_project_and_model_columns
  output = Formatters::Table.render(rows, hide_project: true, hide_model: true)
  header = output.lines.first

  assert header.start_with?("Date"), "Date should lead the header, got: #{header.inspect}"
  refute_includes header, "Project"
  refute_includes header, "Model"
  assert_includes output, "TOTAL" # totals label survives in the Date column
end

def test_csv_ignores_hide_model
  assert_equal Formatters::Csv.render(rows), Formatters::Csv.render(rows, hide_model: true)
end

def test_json_ignores_hide_model
  assert_equal Formatters::Json.render(rows), Formatters::Json.render(rows, hide_model: true)
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bundle exec ruby -Itest test/clauditor/formatters_test.rb -n /hide_model|both_project_and_model/`
Expected: FAIL — `unknown keyword: :hide_model` (ArgumentError).

- [ ] **Step 3: Implement the elision in `lib/clauditor/formatters.rb`**

Replace the `HEADERS` constant and the `render`/`columns`/`totals_row` methods inside `module Table` with:

```ruby
LABEL_HEADERS = [ "Project", "Date", "Model" ].freeze
NUMERIC_HEADERS = [ "Input", "Output", "Cache Write", "Cache Read", "Cost" ].freeze

# When hide_project / hide_model are set the corresponding leading label
# column is dropped — used when the output has been filtered to a single
# project and/or a single model. Date always remains, so at least one label
# column survives for the TOTAL label.
def render(rows, hide_project: false, hide_model: false)
  labels = label_headers(hide_project, hide_model)
  headers = labels + NUMERIC_HEADERS
  table = rows.map { |row| columns(row, hide_project, hide_model) }
  table << totals_row(rows, labels.size)
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

def label_headers(hide_project, hide_model)
  headers = []
  headers << "Project" unless hide_project
  headers << "Date"
  headers << "Model" unless hide_model
  headers
end

def columns(row, hide_project = false, hide_model = false)
  labels = []
  labels << ProjectNormalizer.display(row.project) unless hide_project
  labels << row.date
  labels << row.model unless hide_model
  labels + [
    Formatters.delimit(row.usage.input),
    Formatters.delimit(row.usage.output),
    Formatters.delimit(row.usage.cache_write),
    Formatters.delimit(row.usage.cache_read),
    Formatters.cost_cell(row.cost),
  ]
end

# "TOTAL" sits in the first surviving label column; the rest are blank.
def totals_row(rows, label_cols)
  usage = rows.map(&:usage).reduce(Usage.new, :+)
  priced = rows.select(&:priced?).sum(&:cost)
  labels = [ "TOTAL" ] + Array.new(label_cols - 1, "")
  labels + [
    Formatters.delimit(usage.input),
    Formatters.delimit(usage.output),
    Formatters.delimit(usage.cache_write),
    Formatters.delimit(usage.cache_read),
    Formatters.cost_cell(priced),
  ]
end
```

Update `module Csv` — change the signature and the ignore line:

```ruby
def render(rows, hide_project: false, hide_model: false)
  _ = hide_project
  _ = hide_model
```

Update `module Json` identically:

```ruby
def render(rows, hide_project: false, hide_model: false)
  _ = hide_project
  _ = hide_model
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bundle exec ruby -Itest test/clauditor/formatters_test.rb`
Expected: PASS (all, including the pre-existing `hide_project` tests).

- [ ] **Step 5: Lint**

Run: `bundle exec rake lint:rubocop`
Expected: no offenses.

- [ ] **Step 6: Commit**

```bash
git add lib/clauditor/formatters.rb test/clauditor/formatters_test.rb
git commit -m "Elide Model column in flat table when hidden"
```

---

### Task 2: `Rollup::Table` model-column elision + both-hidden guard

Rollup has no always-present Date column, so hiding both project and model would leave zero label columns. Guard: when both would be hidden, keep the `Model` label.

**Files:**
- Modify: `lib/clauditor/rollup.rb`
- Test: `test/clauditor/rollup_test.rb`

**Interfaces:**
- Produces: `Rollup::Table.render(rows, verbose: false, hide_project: false, hide_model: false)`, `Rollup::Csv.render(rows, verbose: false, hide_project: false, hide_model: false)`, `Rollup::Json.render(rows, verbose: false, hide_project: false, hide_model: false)`.

- [ ] **Step 1: Write the failing tests**

Add to `test/clauditor/rollup_test.rb` (the `row(project:, date:, model:, input:, cost:)` helper already exists):

```ruby
def test_table_drops_model_column_when_hidden
  rows = [
    row(project: "/Users/me/a", date: "2026-06-07", model: "opus-4-8", input: 100, cost: 1.5),
    row(project: "/Users/me/b", date: "2026-06-07", model: "opus-4-8", input: 50, cost: 0.9),
  ]

  lines = Rollup::Table.render(rows, hide_model: true).lines

  assert_includes lines[0], "Project"
  refute_includes lines[0], "Model"
  refute(lines.any? { |line| line.include?("opus-4-8") })
  assert(lines.any? { |line| line.start_with?("TOTAL") })
end

def test_table_both_hidden_keeps_model_label
  rows = [ row(project: "/Users/me/a", date: "2026-06-07", model: "opus-4-8", input: 100, cost: 1.5) ]

  lines = Rollup::Table.render(rows, hide_project: true, hide_model: true).lines

  # No always-present label column exists here, so Model is kept rather than
  # leaving the view with no row labels at all.
  refute_includes lines[0], "Project"
  assert lines[0].start_with?("Model"), "Model label should be kept, got: #{lines[0].inspect}"
  assert(lines.any? { |line| line.include?("opus-4-8") })
  assert(lines.any? { |line| line.start_with?("TOTAL") })
end

def test_csv_ignores_hide_model
  rows = [ row(project: "/Users/me/a", date: "2026-06-07", model: "opus-4-8", input: 100, cost: 1.5) ]
  assert_equal Rollup::Csv.render(rows), Rollup::Csv.render(rows, hide_model: true)
end

def test_json_ignores_hide_model
  rows = [ row(project: "/Users/me/a", date: "2026-06-07", model: "opus-4-8", input: 100, cost: 1.5) ]
  assert_equal Rollup::Json.render(rows), Rollup::Json.render(rows, hide_model: true)
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bundle exec ruby -Itest test/clauditor/rollup_test.rb -n /hide_model|both_hidden/`
Expected: FAIL — `unknown keyword: :hide_model`.

- [ ] **Step 3: Implement the elision in `lib/clauditor/rollup.rb`**

Replace the `HEADERS` constant and the `render`/`columns`/`totals_row` methods inside `module Table` with:

```ruby
LABEL_HEADERS = [ "Project", "Model" ].freeze
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
  drop_model = labels == [ "Project" ] ? false : hide_model
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

def columns(row, verbose, hide_project, hide_model)
  labels = []
  labels << ProjectNormalizer.display(row.project) unless hide_project
  labels << row.model unless hide_model
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
```

Note: in `render`, `columns` receives `drop_model` (not the raw `hide_model`) so the both-hidden guard — which keeps the Model *header* — also keeps the Model *cell*; the header and the cells stay in lockstep.

Update `module Csv` and `module Json` signatures to add `hide_model:` alongside the existing ignores:

```ruby
def render(rows, verbose: false, hide_project: false, hide_model: false)
  _ = verbose
  _ = hide_project
  _ = hide_model
```

Apply that same three-line ignore block to both `Csv.render` and `Json.render`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bundle exec ruby -Itest test/clauditor/rollup_test.rb`
Expected: PASS (all, including pre-existing `hide_project` and verbose tests).

- [ ] **Step 5: Lint**

Run: `bundle exec rake lint:rubocop`
Expected: no offenses.

- [ ] **Step 6: Commit**

```bash
git add lib/clauditor/rollup.rb test/clauditor/rollup_test.rb
git commit -m "Elide Model column in rollup table, guarding the both-hidden case"
```

---

### Task 3: `Crosstab::Table` drops the Total group under one model

In the crosstab models are spread across columns. When `hide_model` is set (one model survives the filter), drop the now-redundant trailing `Total` group. `Csv` accepts and ignores the flag.

**Files:**
- Modify: `lib/clauditor/crosstab.rb`
- Test: `test/clauditor/crosstab_test.rb`

**Interfaces:**
- Consumes: `Crosstab.pivot(rows, summary:)` → `[models, keys, cells]` (unchanged).
- Produces: `Crosstab::Table.render(rows, verbose: false, hide_project: false, hide_model: false, summary: false)`, `Crosstab::Csv.render(rows, verbose: false, hide_project: false, hide_model: false, summary: false)`.

- [ ] **Step 1: Write the failing tests**

Look at the top of `test/clauditor/crosstab_test.rb` for the existing row-builder helper (used by tests like `test_table_totals_each_model_column`). Add tests that build a single-Anthropic-model dataset and assert the Total group disappears when `hide_model: true`:

```ruby
def test_table_drops_total_group_when_model_hidden
  single = [
    Aggregator::Row.new(
      project: "/Users/me/a",
      date: "2026-06-07",
      model: "opus-4-8",
      usage: Usage.new(input: 100, output: 10),
      cost: 1.5,
    ),
  ]

  with_total = Crosstab::Table.render(single).lines[0]
  without_total = Crosstab::Table.render(single, hide_model: true).lines[0]

  assert_includes with_total, "Total"
  refute_includes without_total, "Total"
  # The single model's own group is still present.
  assert_includes without_total, "opus-4-8"
end

def test_csv_ignores_hide_model
  single = [
    Aggregator::Row.new(
      project: "/Users/me/a",
      date: "2026-06-07",
      model: "opus-4-8",
      usage: Usage.new(input: 100, output: 10),
      cost: 1.5,
    ),
  ]
  assert_equal Crosstab::Csv.render(single), Crosstab::Csv.render(single, hide_model: true)
end
```

(If a shared row-builder helper already exists in this file, use it instead of the inline `Aggregator::Row.new` literals — match the file's convention.)

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bundle exec ruby -Itest test/clauditor/crosstab_test.rb -n /hide_model/`
Expected: FAIL — `unknown keyword: :hide_model`.

- [ ] **Step 3: Implement in `lib/clauditor/crosstab.rb`**

In `module Table`, change `render` to accept `hide_model:` and conditionally omit the `TOTAL_GROUP` from the `groups` list. The `data_row`/`totals_row` helpers append the Total pair unconditionally, so they must also become Total-aware. Replace `render`, `data_row`, and `totals_row` with:

```ruby
def render(rows, verbose: false, hide_project: false, hide_model: false, summary: false)
  models, keys, cells = Crosstab.pivot(rows, summary: summary)
  # One surviving model makes the trailing Total group redundant with that
  # model's own pair, so drop it when the caller hid the model dimension.
  show_total = !hide_model
  groups = show_total ? models + [ TOTAL_GROUP ] : models

  labels = hide_project ? LABELS.take(1) : LABELS
  flat_headers = labels + groups.flat_map { SUBCOLUMNS }
  data = keys.map { |key| data_row(key, models, cells, verbose, hide_project, show_total) }
  total = totals_row(models, cells, verbose, hide_project, show_total)

  widths = widen_for_model_names(flat_widths(flat_headers, data + [ total ]), groups, labels.size)
  aligns = Array.new(labels.size, :left) + Array.new(groups.size * 2, :right)

  lines = [ top_header(groups, widths, labels.size), format_flat(flat_headers, widths, aligns), separator(widths) ]
  data.each { |row| lines << format_flat(row, widths, aligns) }
  lines << separator(widths)
  lines << format_flat(total, widths, aligns)
  "#{lines.join("\n")}\n"
end

def data_row(key, models, cells, verbose, hide_project, show_total)
  row = hide_project ? [ key.first ] : [ key.first, ProjectNormalizer.display(key.last) ]
  present = models.filter_map { |model| cells[key][model] }
  models.each do |model|
    cell = cells[key][model]
    row << (cell ? tokens(cell.usage.total, verbose) : "")
    row << (cell ? "$#{Formatters.delimit_decimal(cell.cost)}" : "")
  end
  if show_total
    row << tokens(present.sum(0) { |cell| cell.usage.total }, verbose)
    row << "$#{Formatters.delimit_decimal(present.sum(0.0, &:cost))}"
  end
  row
end

def totals_row(models, cells, verbose, hide_project, show_total)
  row = hide_project ? [ "TOTAL" ] : [ "TOTAL", "" ]
  all = cells.values.flat_map(&:values)
  models.each do |model|
    present = cells.values.filter_map { |by_model| by_model[model] }
    row << tokens(present.sum(0) { |cell| cell.usage.total }, verbose)
    row << "$#{Formatters.delimit_decimal(present.sum(0.0, &:cost))}"
  end
  if show_total
    row << tokens(all.sum(0) { |cell| cell.usage.total }, verbose)
    row << "$#{Formatters.delimit_decimal(all.sum(0.0, &:cost))}"
  end
  row
end
```

Update `module Csv.render` to accept and ignore the flag:

```ruby
def render(rows, verbose: false, hide_project: false, hide_model: false, summary: false)
  _ = verbose
  _ = hide_project
  _ = hide_model
```

(Leave the rest of `Csv.render` unchanged.)

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bundle exec ruby -Itest test/clauditor/crosstab_test.rb`
Expected: PASS (all, including pre-existing tests — `show_total` defaults keep the Total group when `hide_model` is false).

- [ ] **Step 5: Lint**

Run: `bundle exec rake lint:rubocop`
Expected: no offenses.

- [ ] **Step 6: Commit**

```bash
git add lib/clauditor/crosstab.rb test/clauditor/crosstab_test.rb
git commit -m "Drop crosstab Total group when a single model is shown"
```

---

### Task 4: `model` config key

Mirror `--model` as a config key so `~/.clauditor_config` can set a default (overridden by the CLI flag).

**Files:**
- Modify: `lib/clauditor/config.rb`
- Test: `test/clauditor/config_test.rb`

**Interfaces:**
- Produces: `Config.load` returns `{ model: <String> }` when the YAML has a `model:` key.

- [ ] **Step 1: Write the failing test**

Look at `test/clauditor/config_test.rb` for the existing helper that writes a temp YAML and loads it (the `project` and `rollup`/`days` tests use it). Following that pattern, add:

```ruby
def test_translates_model
  with_config("model: opus") do |path|
    assert_equal "opus", Config.load(path: path)[:model]
  end
end
```

If the file's helper has a different name/shape than `with_config`, match it exactly (e.g. the pattern used by `test_translates_rollup_days_since`).

- [ ] **Step 2: Run the test to verify it fails**

Run: `bundle exec ruby -Itest test/clauditor/config_test.rb -n test_translates_model`
Expected: FAIL — raises `ArgumentError: …: unknown option 'model'`.

- [ ] **Step 3: Implement in `lib/clauditor/config.rb`**

In `Config.translate`'s `case` statement, add a `model` branch next to the `project` branch:

```ruby
when "project"
  options[:project] = value&.to_s
when "model"
  options[:model] = value&.to_s
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bundle exec ruby -Itest test/clauditor/config_test.rb -n test_translates_model`
Expected: PASS.

- [ ] **Step 5: Lint**

Run: `bundle exec rake lint:rubocop`
Expected: no offenses.

- [ ] **Step 6: Commit**

```bash
git add lib/clauditor/config.rb test/clauditor/config_test.rb
git commit -m "Mirror --model as a config key"
```

---

### Task 5: CLI wiring, integration tests, and docs

Add the `--model` flag, the `filter_models` step, the `hide_model` computation, thread both `hide_project` and `hide_model` into all three renderer families, and document the flag.

**Files:**
- Modify: `lib/clauditor/cli.rb`
- Modify: `CLAUDE.md`
- Test: `test/clauditor/cli_test.rb`

**Interfaces:**
- Consumes: `Formatters.for(fmt).render(rows, hide_project:, hide_model:)`, `Rollup.for(fmt).render(rows, verbose:, hide_project:, hide_model:)`, `Crosstab.for(fmt).render(rows, verbose:, hide_project:, hide_model:, summary:)` (Tasks 1–3); `Config.load` may supply `options[:model]` (Task 4).

- [ ] **Step 1: Write the failing integration tests**

Add to `test/clauditor/cli_test.rb`. The `with_fixture_root` helper writes one `opus-4-8` project (`/Users/me/proj`); a second root supplies a `haiku-4-5` project so a two-model dataset exists.

```ruby
def test_model_filter_matches_prefix_and_elides_model_column
  with_fixture_root do |root|
    status, out, = run_cli([ "--root", root, "--utc", "--model", "opus" ])

    assert_equal 0, status
    assert_includes out, "100" # opus row survives
    refute_includes out.lines.first, "Model" # single model → column elided
  end
end

def test_model_filter_case_insensitive
  with_fixture_root do |root|
    status, out, = run_cli([ "--root", root, "--utc", "--model", "OPUS" ])

    assert_equal 0, status
    assert_includes out, "100"
  end
end

def test_model_filter_excludes_non_matching
  with_fixture_root do |root|
    _status, out, = run_cli([ "--root", root, "--utc", "--model", "haiku" ])

    refute_includes out, "opus-4-8"
  end
end

def test_model_filter_matching_multiple_models_keeps_column
  with_fixture_root do |a|
    Dir.mktmpdir do |b|
      File.write(File.join(b, "s.jsonl"), <<~JSONL)
        {"type":"assistant","cwd":"/Users/me/proj","timestamp":"2026-06-07T12:00:00.000Z","message":{"id":"b1","model":"claude-haiku-4-5","usage":{"input_tokens":50,"output_tokens":5}}}
      JSONL

      # No --model given: both opus and haiku are present, so the Model column
      # stays.
      status, out, = run_cli([ "--root", a, "--root", b, "--utc" ])

      assert_equal 0, status
      assert_includes out.lines.first, "Model"
      assert_includes out, "opus-4-8"
      assert_includes out, "haiku-4-5"
    end
  end
end

def test_model_filter_from_config_default
  Dir.mktmpdir do |dir|
    config = File.join(dir, "cfg.yml")
    File.write(config, "model: opus\n")
    with_fixture_root do |root|
      status, out, = run_cli([ "--root", root, "--utc" ], config_path: config)

      assert_equal 0, status
      assert_includes out, "100"
      refute_includes out.lines.first, "Model"
    end
  end
end
```

Note: `run_cli` accepts `config_path:` (see the helper at the top of the file).

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bundle exec ruby -Itest test/clauditor/cli_test.rb -n /model_filter/`
Expected: FAIL — `--model` is an invalid option (`OptionParser::InvalidOption`), surfaced as exit status 1.

- [ ] **Step 3: Implement the CLI wiring in `lib/clauditor/cli.rb`**

(a) Add `model: nil` to the built-in defaults hash in `parse` (next to `project: nil`):

```ruby
project: nil,
model: nil,
```

(b) Add the flag to the `OptionParser` block, right after the `--project` option:

```ruby
opts.on("--model NAME", "Only include models whose id starts with NAME (prefix match)") do |name|
  options[:model] = name
end
```

(c) Add the `filter_models` method next to `filter_projects`:

```ruby
# Keeps rows whose model id starts with the given term, case-insensitively.
# Prefix (not substring) — `--model opus` matches `opus-4-8`. row.model is the
# already-normalized/displayed id. Returns all rows when no term is set.
def filter_models(rows, term)
  return rows if term.nil?

  needle = term.downcase
  rows.select { |row| row.model.downcase.start_with?(needle) }
end
```

(d) In `run`, apply the model filter and compute `hide_model`. Change the filter/hide block (currently lines ~42–48) to:

```ruby
rows = filter_projects(rows, options[:project])
rows = filter_models(rows, options[:model])
rows = window_rows(rows, days: options[:days], since: options[:since], timezone: options[:timezone]) if options[:rollup]

# When a --project / --model filter has narrowed the output to a single
# project / model the corresponding column is redundant; drop it from the
# human-readable views (CSV/JSON keep it, and ignore the flags).
hide_project = !options[:project].nil? && rows.map(&:project).uniq.size == 1
hide_model = !options[:model].nil? && rows.map(&:model).uniq.size == 1
```

(e) Thread `hide_model` into all three render calls:

```ruby
if options[:rollup]
  out.print Rollup.for(options[:format]).render(rows, verbose: options[:verbose], hide_project: hide_project, hide_model: hide_model)
elsif options[:anthropic]
  out.print Crosstab.for(options[:format]).render(
    rows,
    verbose: options[:verbose],
    hide_project: hide_project,
    hide_model: hide_model,
    summary: options[:summary],
  )
else
  out.print Formatters.for(options[:format]).render(rows, hide_project: hide_project, hide_model: hide_model)
end
```

- [ ] **Step 4: Run the new tests, then the full suite**

Run: `bundle exec ruby -Itest test/clauditor/cli_test.rb -n /model_filter/`
Expected: PASS.

Run: `bundle exec rake test`
Expected: PASS — entire suite green.

- [ ] **Step 5: Update `CLAUDE.md`**

Make three edits:

1. In the "What this is" usage line, add `--model NAME` after `--project NAME`:

```
[--project NAME] [--model NAME] [--utc] ...
```

2. In the `Formatters` bullet, extend the `--project` filtering sentence to cover `--model`. Append after the existing sentence about `hide_project`:

> A parallel `--model NAME` filter keeps rows whose model id *starts with* `NAME` (case-insensitive prefix, distinct from `--project`'s substring match); when it narrows the output to a single model the flat and rollup tables drop the now-redundant Model column (`hide_model`), and the `--anthropic` crosstab drops its trailing `Total` group. CSV/JSON accept the flag and always keep the model column(s).

3. In the `Config` bullet, add `model` to the list of mirrored keys (it already lists `project`); no structural change beyond naming it.

- [ ] **Step 6: Lint**

Run: `bundle exec rake lint:rubocop`
Expected: no offenses.

- [ ] **Step 7: Commit**

```bash
git add lib/clauditor/cli.rb test/clauditor/cli_test.rb CLAUDE.md
git commit -m "Add --model prefix filter with single-model column elision"
```

---

## Self-Review Notes

- **Spec coverage:** matching (prefix, case-insensitive, no-match, absent) → Task 5 tests; `hide_model` gating → Task 5; flat table elision → Task 1; rollup elision + both-hidden guard → Task 2; crosstab Total drop → Task 3; CSV/JSON keep columns → Tasks 1–3 ignore-tests; config key → Task 4; docs → Task 5 Step 5. All spec sections mapped.
- **Type consistency:** every renderer gains a `hide_model:` keyword; the CLI passes `hide_model:` to all three `.for(...).render` calls; `filter_models`/`hide_model` names are used consistently. `Rollup::Table` internally passes a computed `drop_model` (not raw `hide_model`) to `columns` so header and cells agree under the both-hidden guard.
- **Summary quirk** (documented in spec): `hide_model` counts distinct raw `row.model`, so `--anthropic --summary` with two same-family versions keeps the Total group. No task needs to special-case it.
