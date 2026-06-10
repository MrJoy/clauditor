# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.0.1] - 2026-06-10

### Added

- Initial release: per-project, per-day, per-model report of Claude Code token
  usage and estimated cost.
- `table`, `csv`, and `json` output formats (`--format`).
- `--anthropic` crosstab view spreading Anthropic models across columns.
- `--utc`, `--verbose`, `--project`, `--root`, `--no-store`, and `--store-dir`
  options.
- Persistent dataset under `~/.clauditor` so history survives Claude Code's
  transcript retention window.
- `--version` option.

[Unreleased]: https://github.com/MrJoy/clauditor/compare/v0.0.1...HEAD
[0.0.1]: https://github.com/MrJoy/clauditor/releases/tag/v0.0.1
