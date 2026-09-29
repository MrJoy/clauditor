# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `--root` (and the `roots` config key) accept a Claude Code config directory such as `~/.claude` or `~/.claude-work`. A directory with a `projects/` subdirectory resolves to it, so other `*.jsonl` files in the config dir (history, jobs) aren't scanned, and `~/.claude` shares a stored dataset with `~/.claude/projects`.
- Add Sonnet 5.5 pricing ($2/$10 per MTok).

### Changed

- The persistent dataset is stored per root instead of per root set. Each run loads and saves one file for each root it scans, and a root nested inside another root is dropped, since the outer root already covers it. The file for a single root keeps the name and format that root had under 0.0.2 and 0.0.3, so a default-root dataset carries over as-is.
- Datasets from 0.0.2 and 0.0.3 that don't match a single current root are kept as read-only archives. That covers multi-root datasets, plus single-root ones whose root now resolves to its `projects/` subdirectory. They can't be split by root, so a run uses an archive only when it scans every root the archive covers. It then takes, cell by cell, the larger of the archive's figure and the sum of those roots' own figures, because either source may have lost transcripts the other kept. A run that includes only some of an archive's roots doesn't use it, and falls back to those roots' own datasets for the days the archive held.

### Fixed

- Adding or removing a `--root` no longer hides stored history. Since 0.0.2 the dataset was keyed by the whole root set, so any new combination of roots started empty and fell back to whatever transcripts Claude Code still retained (about 30 days). Older days stayed in the previous dataset file, which nothing read.
- Sonnet 5 stays at $2/$10 per MTok. Anthropic cancelled the scheduled 2026-09-01 increase to $3/$15, which clauditor had been applying to usage from September onward.

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

- The persistent dataset is now keyed by the (sorted, de-duplicated) root set rather than a single root. Existing single-root caches are invalidated once and rebuilt on the next run. A consequence this entry originally left out: every distinct root set got its own empty dataset, so changing roots dropped history older than transcript retention from reports. Fixed in the release after 0.0.3.

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
