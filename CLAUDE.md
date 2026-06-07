# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Clauditor is a Ruby tool that reviews Claude Code session and tool-result data and produces a
per-project, per-day, per-model report of token usage and estimated cost. Run it via
`bundle exec bin/clauditor [--format table|csv|json] [--utc] [--root DIR]`.

## Commands

```bash
bundle intall
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

- **`SessionLoader`** discovers and streams parsed records from `~/.claude/projects/**/*.jsonl` (overridable via `--root`). Malformed lines are skipped — transcripts are append-only and a truncated last line is normal.
- **`Aggregator`** is the heart. Claude Code writes one JSONL line per content block, and **every line sharing a `message.id` repeats the same message-level `usage`** — so it dedupes by `message.id` *globally* (resumed sessions replay earlier messages into new files). Summing raw lines overcounts several-fold. It groups by `(project, day, model)`, sums usage, and costs each cell.
- **`Usage`** is the value object for the four billable dimensions. Cache-creation tokens are kept split by TTL (5-minute vs 1-hour) because they're priced differently; `cache_write` re-sums them for display.
- **`Pricing`** holds per-model USD/MTok rates plus cache multipliers (read 0.1×, 5m write 1.25×, 1h write 2×). `normalize_model` reduces Claude ids to a concise name — dropping the `claude-` prefix and any trailing date stamp (`claude-haiku-4-5-20251001` → `haiku-4-5`) — which is also the id the report groups and displays by; non-Claude ids pass through untouched and cost `nil` (e.g. `<synthetic>`, `qwen…`) rather than guessing.
- **`ProjectNormalizer`** collapses sessions back to their logical repo. Subdirectories collapse to the repo root via `repo_root`, which walks up to the nearest ancestor containing a `.git` entry (dir = checkout, file = worktree). On top of that, anything under `<repo>/.claude/…` truncates to `<repo>`, and externally-managed `…/tmp/worktrees/<repo>/<name>` yields a loose repo name that a second pass (`build_remap`) reattaches to the unique canonical checkout. `Aggregator` memoizes `repo_root` (and accepts an injected resolver) so it isn't a filesystem hit per record.
- **`Formatters`** has `Table` (aligned, with a TOTAL row), `Csv`, and `Json` submodules. Unpriced rows render cost as `—` / blank / `null`+`priced:false`.

Days bucket in **local time** by default; `--utc` switches to UTC. `test_helper.rb` starts SimpleCov, puts `lib/` on the load path, and requires `clauditor`.

## Structure notes

- `Rakefile` auto-loads every `lib/tasks/**/*.rake` file, so new Rake tasks just need to be dropped
  into `lib/tasks/`.
- The `Gemfile` references a not-yet-created `lib/tasks/github_export.rake` (the reason `csv` is an
  explicit dependency — it was removed from Ruby 3.4 default gems). Expect data-export/import tooling
  to live under `lib/tasks/`.
- `rake cloc` excludes `data/`, `docs/`, `coverage/`, `vendor/`, etc. — these are the expected
  locations for input session data and generated output.
