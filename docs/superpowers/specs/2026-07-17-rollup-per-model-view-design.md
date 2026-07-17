# Design: `--rollup` per-model view

**Date:** 2026-07-17
**Status:** Approved (pending spec review)

## Goal

Add a view that shows token-count totals and cost **per model, aggregated across
time** — collapsing the per-day breakdown into an all-time (or windowed) total.
Support filtering by project (already available) and controlling how far back the
rollup reaches.

## CLI surface

| Flag | Effect |
| --- | --- |
| `--rollup` | Collapse the date dimension. Output is one row per `(project, model)`, usage and cost summed across the window, sorted by project then model. Works in **table, csv, and json**. |
| `--days N` | Keep only rows dated within the last `N` days, **including today**, in the active timezone (`--utc` aware). `--days 1` = today only; `--days 7` = today plus the prior 6. Rollup-only. |
| `--since YYYY-MM-DD` | Absolute inclusive cutoff: keep rows with `date >= DATE`. Rollup-only. |

### Validation rules

- `--days` and `--since` are **mutually exclusive** → passing both is an error
  (`clauditor: --days and --since cannot be combined`).
- `--days` / `--since` are **rollup-only** → passing either without `--rollup` is
  an error (`clauditor: --days requires --rollup`, `clauditor: --since requires
  --rollup`). This avoids a flag silently doing nothing.
- `--rollup` and `--anthropic` are **mutually exclusive** → passing both is an
  error (`clauditor: --rollup and --anthropic cannot be combined`).
- `--days N` must be a positive integer; `--since` must parse as `YYYY-MM-DD`.
  Bad values raise `ArgumentError`, caught by the CLI and printed as
  `clauditor: …` (consistent with existing flag/config error handling).

### Interaction with existing flags

- `--project` continues to filter. In the rollup view the project column is
  dropped only when the post-filter result narrows to a **single** project —
  the same rule the flat `Table` and crosstab `Table` already apply. Multi-match
  `--project` keeps the column so rows stay unambiguous.
- `--verbose` has no abbreviation to toggle here: the rollup table shows full
  (delimited) token counts always, like the flat table. The flag is accepted but
  inert for this view (same as CSV/JSON ignoring it).
- CSV/JSON always keep the project column (matching current behavior).

## Architecture

A new module **`Clauditor::Rollup`**, parallel to `Clauditor::Crosstab`. It owns
both the collapse and the rendering:

- `Rollup.for(format)` dispatches to `Rollup::Table` / `Rollup::Csv` /
  `Rollup::Json` (raising `ArgumentError` on an unknown format, mirroring
  `Formatters.for` / `Crosstab.for`).
- Each submodule takes the already-filtered, already-windowed `Row`s plus
  `hide_project:` and renders. They reuse `Formatters.delimit`,
  `Formatters.delimit_decimal`, and the `cost_cell` "—"/blank/null convention.

### Collapse

Group the incoming `Row`s by `(project, model)`:

- **Sum usage** via `Usage#+`.
- **Sum the already-computed per-row `cost`**, nil-safe — mirroring the existing
  `Table.totals_row` (`rows.select(&:priced?).sum(&:cost)`) and the `--summary`
  crosstab merge. Summing precomputed per-day costs (rather than re-costing the
  summed usage against a single date) keeps **tiered pricing correct** across a
  price-change boundary (e.g. `sonnet-5`'s 2026-08-31 cutoff) and preserves the
  unpriced (`nil` cost, `priced? == false`) state for non-Claude models.
- A collapsed cell is unpriced iff **none** of its component rows were priced.

The collapsed cells sort by project then model.

### Window filter

A small private CLI helper `window_rows(rows, days:, since:, timezone:)`:

- With `--days N`: cutoff = (today in active tz) − (N−1) days; keep
  `row.date >= cutoff.strftime("%Y-%m-%d")`.
- With `--since DATE`: keep `row.date >= DATE`.
- `unknown`-dated rows are **dropped** when a window is active (they can't be
  placed on the timeline) and **included** when no window is set.
- "Today" is computed from the active timezone the same way the aggregator
  buckets days, so `--utc` and local stay consistent.

## Data flow

The core pipeline (`SessionLoader` → `Aggregator` → `rows`) and the `Store` are
**unchanged**. The rollup is a post-processing/rendering branch in `CLI#run`:

```
rows = aggregator.rows
store&.save(rows)                     # store still persists the COMPLETE dataset
rows = filter_projects(rows, project) # existing
rows = window_rows(rows, ...)         # NEW, only when --rollup + a window flag
hide_project = single-project rule    # existing computation, reused
if options[:rollup]
  out.print Rollup.for(format).render(rows, hide_project:)
elsif options[:anthropic]
  out.print Crosstab.for(format).render(...)
else
  out.print Formatters.for(format).render(rows, hide_project:)
end
```

The store saves before any filtering/windowing, so the persisted dataset stays
complete regardless of what a given run displays.

## Config mirrors

For consistency with the existing "every flag mirrors a config key (except
`remap`)" convention, add config keys:

- `rollup` (boolean)
- `days` (positive integer)
- `since` (`YYYY-MM-DD` string)

They flow through `Config.load` into the same option symbols and are layered as
**built-in defaults < config file < CLI flags**, exactly like the others. The
same validation applies: `days`/`since` require `rollup`, `days`/`since` are
mutually exclusive, `rollup` conflicts with `anthropic`. Validation lives where
the final merged option set is known (after `CLI#parse` layers config + CLI), so
a conflict arising from any mix of sources is caught. Ill-typed values
(`days: "soon"`, `since: 12345`, non-date string) raise `ArgumentError` from
`Config`.

## Output shape

### Table (`--rollup`)

```
Project     Model      Input    Output  Cache Write  Cache Read      Cost
--------    --------   ------   -------  -----------  ----------  --------
clauditor   opus-4-8    1,234    5,678      900,000   1,200,000   $12.34
clauditor   sonnet-5      500    2,000      100,000     300,000    $2.10
--------    --------   ------   -------  -----------  ----------  --------
TOTAL                   1,734    7,678    1,000,000   1,500,000   $14.44
```

With `--project` narrowing to one project, the `Project` column is dropped and
`TOTAL` shifts into the `Model` column (mirroring the flat table's behavior).

### CSV / JSON

Same fields as the flat formatters minus `date`: `project, model, input_tokens,
output_tokens, cache_creation_tokens, cache_read_tokens, total_tokens, cost_usd`
(JSON also `priced`). Project column always present.

## Testing

- **`test/clauditor/rollup_test.rb`** — collapse correctness (usage + cost
  summation across dates), all three renderers, `hide_project`, tiered-pricing
  cost summation across a boundary, unpriced-model handling, `unknown`-date
  handling, empty input, `TOTAL` row.
- **CLI tests** — `--rollup` parsing and dispatch per format; `--days`/`--since`
  parsing; window math at day boundaries (including `--utc`); the three error
  paths (`days`+`since`, `days`/`since` without `rollup`, `rollup`+`anthropic`);
  bad `--days`/`--since` values; `--project` single-vs-multi project column
  behavior in rollup.
- **Config tests** — `rollup`/`days`/`since` keys load and layer correctly;
  config-sourced conflicts raise; ill-typed values raise.

## Out of scope (YAGNI)

- Combining `--rollup` with `--anthropic` (explicitly an error).
- A per-project subtotal within the rollup (each `(project, model)` row is the
  finest grain; the single `TOTAL` row is the only aggregate).
- Windowing the flat/crosstab views (`--days`/`--since` are rollup-only by
  decision).
