# Clauditor

Clauditor is a Ruby-based tool that reviews Claude session and tool result data and provides a
report per-project, per-day, per-model of your token usage.

Completed days are persisted to `~/.clauditor`, so history survives Claude Code's ~30-day
transcript retention window and repeat runs only re-scan recent files. The current day is always
recomputed live and never persisted. Use `--no-store` to bypass the dataset entirely, or
`--store-dir DIR` to relocate it.
