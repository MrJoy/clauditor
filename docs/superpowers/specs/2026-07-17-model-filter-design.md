# `--model` prefix filter — design

## Summary

Add a `--model NAME` option to clauditor that filters report rows to models
whose id begins with `NAME` (case-insensitive **prefix** match). When the filter
narrows the output to a single model, the redundant model dimension is elided
from the human-readable views (flat table, `--rollup` table, and the
`--anthropic` crosstab); CSV and JSON always keep every column. The flag mirrors
the existing `--project` filter in shape, precedence, and config handling.

## Motivation

Users already scope reports by project (`--project`). Scoping by model is the
natural companion: "show me just my opus usage" or "just haiku, rolled up." When
the result is a single model, the model column/label is pure noise, so we drop
it — the same nicety `--project` already applies to the project column.

## Behavior

### Matching

- `--model NAME` keeps rows whose `row.model` **starts with** `NAME`,
  case-insensitively. `row.model` is the already-normalized/displayed id
  (`opus-4-8`, `haiku-4-5`, `sonnet-5`, or a passed-through non-Claude id), which
  is also what every view groups and prints by — so the filter matches exactly
  what the user sees.
- Prefix (not substring): `--model opus` matches `opus-4-8`; `--model o` matches
  any model starting with `o`. This is deliberately distinct from `--project`,
  which is a substring `include?`.
- No match → zero rows, rendered as an empty body with a zeroed `TOTAL`
  (identical to `--project` with no match).
- Absent flag → all rows (no-op).

### Elision (`hide_model`)

- `hide_model = !options[:model].nil? && rows.map(&:model).uniq.size == 1`.
  Gated on the flag being *set* and decided on the post-filter (and, for rollup,
  post-window) rows — an exact parallel to `hide_project`.
- Applies only to the human-readable table views. CSV/JSON accept the parameter
  for a uniform interface and ignore it, always carrying the model column(s).

## Views

### Flat `Formatters::Table`

Label columns become conditional: `Project?`, `Date` (always present), `Model?`,
followed by the unchanged numeric columns (Input, Output, Cache Write, Cache
Read, Cost). `label_cols` is the count of surviving label columns. `TOTAL` sits
in the first surviving label column with the remaining label columns blank. Both
`hide_project` and `hide_model` can be active at once (single project *and*
single model); `Date` guarantees at least one label column remains.

### `Rollup::Table`

Label columns are `Project?`, `Model?` (this view has no Date column). **Edge
guard:** because there is no always-present label, hiding *both* would leave zero
label columns (this happens only when the data collapses to a single
`(project, model)` cell — one data row plus `TOTAL`). In that case keep the
`Model` label — a per-model rollup with no label is meaningless. So the rule is:
elide `Model` unless doing so would leave no label column at all.

### `Crosstab::Table` (`--anthropic`)

Models are spread across columns rather than living in one label column. The
row-level `--model` filter naturally narrows which model columns appear. When
`hide_model` is set (one model survives), drop the now-redundant trailing
**Total** group (its Tokens/Cost pair duplicates the single model's pair). The
`Date`/`Project?` labels are untouched.

`--model` composes with `--summary`: filtering happens on `row.model` at the CLI
before the crosstab pivots/summarizes, so `--model opus` selects `opus-4-8`
which `--summary` then renders under the `opus` column.

### CSV / JSON (all view families)

`Formatters::Csv`/`Json`, `Rollup::Csv`/`Json`, and `Crosstab::Csv` accept
`hide_model:` and ignore it — machine-readable output always carries the model
column(s), matching how they already treat `hide_project`.

## CLI wiring (`cli.rb`)

- Add the `--model NAME` option to the parser, defaulting `options[:model]` to
  `nil` in the built-in defaults hash.
- Add `filter_models(rows, term)` — `return rows if term.nil?`, else
  `needle = term.downcase; rows.select { |r| r.model.downcase.start_with?(needle) }`.
- Call order: `filter_projects` → `filter_models` → `window_rows` (rollup only).
- Compute `hide_model` next to `hide_project` and thread both into
  `Rollup.for(...).render`, `Crosstab.for(...).render`, and
  `Formatters.for(...).render`.

## Config (`config.rb`)

Add a `model` key to `translate`: `options[:model] = value&.to_s` (mirrors
`project`). CLI flag overrides config, per the existing precedence (built-in
defaults < config file < flags).

## Precedence & interactions

- `--model` is meaningful in every view (flat, rollup, crosstab) and every
  format; no new mutual-exclusion rules. It composes with `--project`,
  `--rollup`/`--days`/`--since`, `--anthropic`/`--summary`, and `--verbose`.
- Known conservative quirk: `hide_model` counts distinct raw `row.model` values.
  Under `--anthropic --summary`, two versions (`opus-4-8`, `opus-4-1`) collapse
  to one `opus` column but count as 2 distinct models, so the Total group is
  kept. Rare and harmless.

## Docs

Update `CLAUDE.md`: the usage line (add `--model NAME`) and the `Formatters`,
`Crosstab`, and `Config` bullets to describe `--model`/`hide_model`.

## Testing

- **CLI**: prefix match (hit), no-match (empty + zero TOTAL), case-insensitivity;
  `hide_model` elision in flat table and rollup table; both-hidden rollup guard
  keeps the Model label; crosstab drops the Total group under one model;
  CSV/JSON keep the model column(s) under the filter.
- **Config**: `model` key populates `options[:model]`; CLI flag overrides it.
- **Formatters/Rollup/Crosstab**: `hide_model:` column/group elision at the unit
  level.
