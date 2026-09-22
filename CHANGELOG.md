# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.0.3] - 2026-09-22

### Added

- `--rollup` collapses the per-day breakdown into per-`(project, model)` totals across all output formats. `--days N` and `--since DATE` restrict the window (rollup-only, mutually exclusive). Mirror keys (`rollup`, `days`, `since`) are available in the config file. The rollup table abbreviates token counts with `k`/`m`/`b` suffixes (like the `--anthropic` crosstab) unless `--verbose`.
- `--model NAME` keeps rows whose model id matches `NAME` exactly (case-insensitive). A trailing `*` switches to prefix matching, so `opus-5` matches only `opus-5`, `opus-5*` also matches `opus-5-5`, and `opus*` matches every Opus model. When the filter narrows output to a single model, the flat and rollup tables drop the Model column and the `--anthropic` crosstab drops its trailing `Total` group. Mirrored as the `model` config key.
- Add support for Opus 5, Fable 5.1, and Opus 5.5 pricing. A model's rates may now carry an explicit cache-read price for models that don't follow the usual 0.1x rule (Fable 5.1 at $0.25/MTok, Opus 5.5 at $0.20/MTok).

## [0.0.2] - 2026-06-30

### Added

- `--root` is now repeatable, so a single report can span several transcript trees. Overlapping/nested roots are de-duplicated.
- Optional YAML config at `~/.clauditor_config` supplying defaults for every option. Command-line flags override the config file.
- Add support for Sonnet 5 pricing, including handling of the early discount period.
- Add `--summary` option for `--anthropic` mode, to collapse different versions of the same model class together.  E.G. `opus-4.6`, `opus-4.7` => `opus`.

### Changed

- The persistent dataset is now keyed by the (sorted, de-duplicated) root set rather than a single root. Existing single-root caches are invalidated once and rebuilt on the next run.

## [0.0.1] - 2026-06-10

### Added

- Initial release: per-project, per-day, per-model report of Claude Code token usage and estimated cost.
- `table`, `csv`, and `json` output formats (`--format`).
- `--anthropic` crosstab view spreading Anthropic models across columns.
- `--utc`, `--verbose`, `--project`, `--root`, `--no-store`, and `--store-dir` options.
- Persistent dataset under `~/.clauditor` so history survives Claude Code's transcript retention window.
- `--version` option.

[Unreleased]: https://github.com/MrJoy/clauditor/compare/v0.0.3...HEAD
[0.0.3]: https://github.com/MrJoy/clauditor/releases/tag/v0.0.3
[0.0.2]: https://github.com/MrJoy/clauditor/releases/tag/v0.0.2
[0.0.1]: https://github.com/MrJoy/clauditor/releases/tag/v0.0.1
