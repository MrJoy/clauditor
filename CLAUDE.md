# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Clauditor is a Ruby tool that reviews Claude Code session and tool-result data and produces a
per-project, per-day, per-model report of token usage and estimated cost. Run it via
`bundle exec bin/clauditor [--format table|csv|json] [--anthropic] [--verbose] [--project NAME] [--utc] [--root DIR ...] [--no-store] [--store-dir DIR]`.
`--root` is repeatable (scans several trees). Defaults can also come from a YAML config at `~/.clauditor_config`; CLI flags override it.

## Commands

```bash
bundle install
bundle exec rake test                              # run the full test suite
bundle exec ruby -Itest test/path/to/foo_test.rb   # run a single test file
bundle exec ruby -Itest test/path/to/foo_test.rb -n test_method_name  # run one test
bundle exec rake lint        # rubocop + bundler-audit
bundle exec rake lint:rubocop
bundle exec rake cloc        # line count, excludes vendored/generated dirs (needs cloc installed)
```

Ruby version is pinned in `.ruby-version` (3.4.8) and the gemset in `.ruby-gemset` (rbenv +
rbenv-gemset assumed).

## Conventions

- Style is **rubocop-rails-omakase** (see `.rubocop.yml`), overridden to require trailing commas in
  multiline array and hash literals. Run `bundle exec rake lint:rubocop` before considering work done.
- All Ruby files use `# frozen_string_literal: true`.
- Gem versions in the `Gemfile` are intentionally left unpinned (`Bundler/GemVersion` is disabled
  inline); RubyGems source has a 7-day `cooldown` to avoid pulling brand-new releases.
- Tests use **minitest** (`minitest/autorun` via `test/test_helper.rb`); coverage via **simplecov**.
  Test files are discovered as `test/**/*_test.rb`.

## Architecture

The pipeline is `bin/clauditor` → `Clauditor::CLI` → loader → aggregator → formatter, with `lib/clauditor.rb` wiring the requires. Key pieces under `lib/clauditor/`:

- **`Config`** loads optional defaults from a YAML file (`~/.clauditor_config`, injectable via `CLI.run(config_path:)` for tests). Every key mirrors a CLI flag and is translated to the same internal option symbols the CLI assembles, so `CLI#parse` layers them as **built-in defaults < config file < flags actually passed**. `--root` is special-cased: any `--root` on the CLI *replaces* the config roots wholesale (collected into a separate `cli_roots` so an absent flag leaves config intact). A missing file contributes nothing; an unknown key, ill-typed value, bad `format`, or malformed YAML raises `ArgumentError` (caught by the CLI and printed as `clauditor: …`).
- **`SessionLoader`** discovers and streams parsed records from `**/*.jsonl` under one or more roots (`roots:` list or a single `root:`; default `~/.claude/projects`, overridable/extendable via repeated `--root`). It globs every root and `uniq`s the file list so nested/overlapping roots never read the same file twice. Malformed lines are skipped — transcripts are append-only and a truncated last line is normal. A `since:` Time skips files whose mtime predates it (record timestamps never exceed the file's mtime).
- **`Store`** persists aggregated cells for *completed* days to `~/.clauditor` (`--store-dir` to relocate, `--no-store` to bypass). A day is complete once the clock passes it, so days strictly before today are persisted and seeded back into the aggregator on the next run; **today is never persisted** — always recomputed live. This survives Claude Code's ~30-day transcript retention and makes warm runs ~10× faster (the loader skips files older than `cutoff_time`, and the aggregator's `skip_through:` drops replayed records from covered days so seeded cells aren't double-counted). Store files are keyed by `(roots, timezone)` — the root set is sorted and de-duplicated so order/repeats don't fork the key, and a single root hashes the same as before (so existing default-root caches survive). Day bucketing differs between `--utc` and local; token counts are persisted rather than costs so pricing updates apply retroactively. Anything unreadable or mismatched (version/roots/timezone) loads as empty and is rebuilt by a full scan; `save` is a wholesale rewrite of the merged rows, done *before* `--project` filtering so the dataset stays complete. Rows dated `unknown` are never persisted or skipped.
- **`Aggregator`** is the heart. Claude Code writes one JSONL line per content block, and **every line sharing a `message.id` repeats the same message-level `usage`** — so it dedupes by `message.id` *globally* (resumed sessions replay earlier messages into new files). Summing raw lines overcounts several-fold. It groups by `(project, day, model)`, sums usage, and costs each cell.
- **`Usage`** is the value object for the four billable dimensions. Cache-creation tokens are kept split by TTL (5-minute vs 1-hour) because they're priced differently; `cache_write` re-sums them for display.
- **`Pricing`** holds per-model USD/MTok rates plus cache multipliers (read 0.1×, 5m write 1.25×, 1h write 2×). `normalize_model` reduces Claude ids to a concise name — dropping the `claude-` prefix and any trailing date stamp (`claude-haiku-4-5-20251001` → `haiku-4-5`) — which is also the id the report groups and displays by; non-Claude ids pass through untouched and cost `nil` (e.g. `<synthetic>`, `qwen…`) rather than guessing.
- **`ProjectNormalizer`** collapses sessions back to their logical repo. Subdirectories collapse to the repo root via `repo_root`, which walks up to the nearest ancestor containing a `.git` entry (dir = checkout, file = worktree). On top of that, anything under `<repo>/.claude/…` truncates to `<repo>`, and externally-managed `…/tmp/worktrees/<repo>/<name>` yields a loose repo name that a second pass (`build_remap`) reattaches to the unique canonical checkout. `Aggregator` memoizes `repo_root` (and accepts an injected resolver) so it isn't a filesystem hit per record.
- **`Formatters`** has `Table` (aligned, with a TOTAL row), `Csv`, and `Json` submodules. Unpriced rows render cost as `—` / blank / `null`+`priced:false`.
- **`Crosstab`** is the `--anthropic` view: it pivots the flat rows to one line per `(day, project)` with Anthropic models spread across columns (non-Anthropic models are dropped). `Table` uses a two-line header (model name spans its Tokens+Cost pair) and appends a trailing `Total` group summing tokens and cost across all models for that row; token counts are abbreviated with `k`/`m`/`b` suffixes unless `--verbose` (costs are never abbreviated). `Csv` emits five model-prefixed columns per model (Input/Output/Cache Write/Cache Read/Cost) and ignores `--verbose` (always full precision). JSON is unsupported — the CLI exits 1 with a message *before* loading data. `--project NAME` filters to rows whose project path (or its `~`-display) contains `NAME`, case-insensitively (works in every view, not just the crosstab). When such a filter narrows the output down to a *single* project, the CLI passes `hide_project: true` and the human-readable table views (flat `Table` and crosstab `Table`) drop the now-redundant project column — the "TOTAL" label shifts left into the Date column. CSV/JSON accept the flag for a uniform interface but ignore it, always keeping the project column.

Days bucket in **local time** by default; `--utc` switches to UTC. `test_helper.rb` starts SimpleCov, puts `lib/` on the load path, and requires `clauditor`.

## Structure notes

- `Rakefile` auto-loads every `lib/tasks/**/*.rake` file, so new Rake tasks just need to be dropped
  into `lib/tasks/`.
- `rake cloc` excludes `data/`, `docs/`, `coverage/`, `vendor/`, etc. — these are the expected
  locations for input session data and generated output.
