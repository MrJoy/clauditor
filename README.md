# Clauditor

Clauditor is a Ruby-based tool that reviews Claude session and tool result data and provides a
report per-project, per-day, per-model of your token usage and estimated cost.

It reads Claude Code's session transcripts from `~/.claude/projects/**/*.jsonl`, dedupes the
repeated per-message usage Claude Code records, groups usage by project, day, and model, and prices
each cell using per-model rates.  It will also track non-Anthropic model usage (e.g.
via `ollama launch claude`), but does not track any applicable pricing.

Completed days are persisted to `~/.clauditor`, so history survives Claude Code's ~30-day
transcript retention window and repeat runs only re-scan recent files. The current day is always
recomputed live and never persisted. Use `--no-store` to bypass the dataset entirely, or
`--store-dir DIR` to relocate it.

## Setup

Clauditor targets the Ruby version pinned in `.ruby-version` (currently **3.4.8**). The repo also
ships a `.ruby-gemset` (`clauditor`) and assumes an rbenv + rbenv-gemset setup, but any Ruby version
manager that honors `.ruby-version` works.

```bash
# From the repo root, with the pinned Ruby active:
bundle install
```

Run it through Bundler:

```bash
bundle exec bin/clauditor
```

By default this prints a table of every project/day/model it finds in `~/.claude/projects`.

## Usage

```bash
bundle exec bin/clauditor [options]
```

### Options

| Option | Description |
| --- | --- |
| `-f`, `--format FORMAT` | Output format: `table`, `csv`, or `json` (default: `table`). |
| `--utc` | Bucket days by UTC instead of local time. |
| `--anthropic` | Crosstab Anthropic models across columns. Supported with `table` and `csv`; **not** `json`. |
| `--verbose` | Show full token counts. The table crosstab abbreviates counts with `k`/`m`/`b` suffixes by default; this disables that. (No effect on CSV, which is always full precision.) |
| `--project NAME` | Only include projects whose path (or its `~`-relative display) contains `NAME`, case-insensitively. |
| `--root DIR` | Session transcripts directory (default: `~/.claude/projects`). |
| `--no-store` | Neither read nor update the persistent dataset. Forces a full live scan. |
| `--store-dir DIR` | Persistent dataset directory (default: `~/.clauditor`). |
| `-h`, `--help` | Show help and exit. |

### Output formats

- **`table`** (default) — aligned columns with a `TOTAL` row. Unpriced rows show cost as `—`.
- **`csv`** — machine-readable; always full precision (ignores `--verbose`).
- **`json`** — structured output. Unpriced rows render cost as `null` with `priced: false`.
  Not supported together with `--anthropic` (the CLI exits with an error before loading data).

### The `--anthropic` crosstab

`--anthropic` pivots the flat report to one line per `(day, project)`, spreading Anthropic models
across columns and dropping non-Anthropic models. The table view uses a two-line header (each model
name spans its Tokens + Cost pair) and appends a trailing `Total` group summing across all models in
that row. The CSV view emits five columns per model (Input / Output / Cache Write / Cache Read /
Cost).

### Examples

```bash
# Default table for everything Clauditor can find
bundle exec bin/clauditor

# CSV, bucketed by UTC days
bundle exec bin/clauditor --format csv --utc

# Anthropic crosstab, full (un-abbreviated) token counts
bundle exec bin/clauditor --anthropic --verbose

# Just one project, as JSON
bundle exec bin/clauditor --project ~/mrjoy/clauditor --format json

# A one-off live scan that touches neither the stored dataset nor your default root
bundle exec bin/clauditor --no-store --root /path/to/transcripts
```

## Notes on cost estimates

Costs are estimates. Pricing is held per-model in USD/MTok, with cache multipliers (read 0.1×,
5-minute cache write 1.25×, 1-hour cache write 2×). Non-Claude models (and synthetic ids) are left
unpriced rather than guessed at, and render as `—` / blank / `null`. Token counts — not costs — are
what gets persisted, so pricing updates apply retroactively on the next run.

## Development

```bash
bundle exec rake test                              # run the full test suite
bundle exec ruby -Itest test/path/to/foo_test.rb   # run a single test file
bundle exec rake lint                              # rubocop + bundler-audit
bundle exec rake lint:rubocop
bundle exec rake cloc                              # line count (needs cloc installed)
```
