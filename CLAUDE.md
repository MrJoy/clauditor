# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Clauditor is a Ruby tool that reviews Claude Code session and tool-result data and produces a
per-project, per-day, per-model report of token usage. The repository is in an early bootstrap
state — the Rake/lint/test scaffolding exists, but the analysis code (`lib/`) and tests have not
been written yet.

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

## Structure notes

- `Rakefile` auto-loads every `lib/tasks/**/*.rake` file, so new Rake tasks just need to be dropped
  into `lib/tasks/`.
- The `Gemfile` references a not-yet-created `lib/tasks/github_export.rake` (the reason `csv` is an
  explicit dependency — it was removed from Ruby 3.4 default gems). Expect data-export/import tooling
  to live under `lib/tasks/`.
- `rake cloc` excludes `data/`, `docs/`, `coverage/`, `vendor/`, etc. — these are the expected
  locations for input session data and generated output.
