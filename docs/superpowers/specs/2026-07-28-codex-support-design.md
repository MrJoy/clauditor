# Codex support — design

Date: 2026-07-28

Add OpenAI Codex CLI usage to clauditor's per-project, per-day, per-model report,
alongside the existing Claude Code data, with real dollar costs drawn from a dated
OpenAI price history.

## 1. The Codex data format

Codex writes append-only JSONL "rollout" files:

- `~/.codex/sessions/YYYY/MM/DD/rollout-<iso>-<uuid>.jsonl`
- `~/.codex/archived_sessions/rollout-<iso>-<uuid>.jsonl` — a disjoint set of
  files (verified: zero filename overlap), not copies. Both directories count.

Relevant record types:

| `type` | `payload.type` | Carries |
| --- | --- | --- |
| `session_meta` | — | `cwd`, `cli_version`, `originator`, `thread_source`, `git.repository_url`, `model` (usually `null`) |
| `turn_context` | — | `model` (authoritative, per turn), `cwd`, `effort` |
| `event_msg` | `token_count` | `info.total_token_usage`, `info.last_token_usage` |

### The delta rule

This is the correctness core of the whole feature.

`token_count` events are frequently emitted **more than once per turn with
identical payloads**. Summing `last_token_usage` therefore over-counts badly —
measured on a real session, naive summing gives 8,363,528 input tokens where the
truth is 4,100,322.

`total_token_usage` is the authoritative running cumulative. So, per rollout file,
streaming in order:

```
delta = current.total_token_usage - previous_total
```

with two guards:

- **Baseline.** For the file's first `token_count` event, `previous_total` is
  initialised to `first.total - first.last`. When a file starts fresh this is
  zero; when a resumed rollout carries forward prior totals, this correctly
  excludes the carried-forward portion.
- **Reset.** If `total` ever *decreases* (a new context window), treat the
  current `total` as the delta and re-baseline.

Duplicate events fall out for free: their delta is zero, so they are skipped
without needing any dedupe bookkeeping. Codex needs no analogue of the Claude
`message.id` dedupe.

`info` may be `null` — those are rate-limit-only heartbeats and are skipped.

### Mapping to `Usage`

`cached_input_tokens` is a **subset** of `input_tokens`, and
`reasoning_output_tokens` is a subset of `output_tokens` (confirmed:
`total_tokens == input_tokens + output_tokens`). So:

| `Usage` field | Source |
| --- | --- |
| `input` | `input_tokens - cached_input_tokens` |
| `cache_read` | `cached_input_tokens` |
| `output` | `output_tokens` |
| `cache_write_5m`, `cache_write_1h` | always `0` — Codex has no cache-write dimension |

### Day bucketing

Sessions can span multiple calendar days (one observed session runs 2026-06-03 →
2026-06-05). Each emitted turn is therefore bucketed by **its own `token_count`
event timestamp**, not the session's start.

## 2. `CodexLoader`

New `lib/clauditor/codex_loader.rb`, parallel in spirit to `SessionLoader`.

```ruby
Turn = Struct.new(:cwd, :timestamp, :model, :usage, keyword_init: true)
```

- Globs `**/*.jsonl` across the codex roots and `uniq`s the result, same as
  `SessionLoader`.
- Honours the same `since:` mtime skip. Rollouts are append-only, so a file
  untouched since the Store's covered window can only hold already-persisted days.
- Skips malformed lines, same rationale as `SessionLoader` (a truncated final
  line is normal in an append-only log).
- Tracks the current `cwd` and `model` from `session_meta` / `turn_context`,
  falling back to `session_meta.payload.model` and then `"unknown"`.
- Yields one `Turn` per non-zero delta.

**Subtlety worth calling out:** a partially-covered file must still be read from
the beginning, because the baseline arithmetic depends on the earlier events.
Per-day filtering stays in the `Aggregator` (via `skip_through`), which already
works this way. `since:` only ever skips a file *wholly*, never mid-file, so this
is consistent.

## 3. `Aggregator` and the `source` dimension

`Aggregator#add(record)` keeps its exact current behaviour for Claude records.
Its body moves into a private `record_usage(source:, cwd:, timestamp:, model:,
usage:)`, and a new public `add_turn(turn)` feeds Codex turns through the same
path with `source: "codex"`.

- Group key becomes `[source, project, day, model]`.
- `Row` gains a `source` member.
- `seed` gains a `source:` keyword.
- Dedupe, `covered?`, remapping and cost assignment are all unchanged.

### Store

`Store::VERSION` → `3`. Rows persist `"source"`; the key incorporates both root
lists (`roots` and `codex_roots`, each sorted and de-duplicated, both stored and
validated on load). The version bump means a one-time full rescan on upgrade, so
no migration path is needed.

## 4. Pricing

### Rate hash shape

Rate hashes gain optional explicit per-dimension rates:

```ruby
{ input:, output:, cache_read:, cache_write_5m:, cache_write_1h: }
```

When a dimension is absent it falls back to the existing multiplier derivation
(`CACHE_READ_MULTIPLIER` 0.1, `CACHE_WRITE_5M_MULTIPLIER` 1.25,
`CACHE_WRITE_1H_MULTIPLIER` 2.0), so **every current Anthropic entry keeps its
exact present behaviour**.

This is required, not cosmetic: OpenAI's cached-input discount is *not* uniformly
0.1×. It is 0.1× across the GPT-5.x line but 0.25× for `o3` and `gpt-4.1`, and
0.5× for `o1`, `o3-mini` and `gpt-4o`. Deriving it would silently misprice older
models.

### Tier convention: `effective:` start dates

The existing `until:` end-date convention is replaced everywhere by `effective:`
start dates, so that recording a new price is a pure append and never an edit of
an existing tier. Tiers stay ordered oldest-first; the **first** tier carries no
`effective:` and so applies to all earlier dates.

```ruby
"sonnet-5" => [
  { input: 2.0, output: 10.0 },
  { effective: "2026-09-01", input: 3.0, output: 15.0 },
],
```

Resolution: pick the **last** tier whose `effective` is `nil` or `<= date`. A
`nil` or `"unknown"` date resolves to the last (current) tier, matching today's
behaviour. `effective: "2026-09-01"` is behaviourally identical to the current
`until: "2026-08-31"`, so the migration is semantics-preserving.

### Baked-in tables

Hand-written Ruby hashes; `openai_prices.tsv` is deleted once transcribed. The
OpenAI table is seeded from two sources:

- **`https://www.aipricing.guru/api/price-history.json`** — 103 dated snapshots
  spanning 2026-04-16 … 2026-07-28. Bare canonical ids (`gpt-5.6-sol`) matching
  what Codex logs. Collapsed into `effective:` tiers by walking snapshots
  oldest-first and emitting a tier only where rates change. Covers 24 OpenAI
  models.
- **The provided TSV snapshot** — supplies what the feed lacks: cache-write rates
  for the 5.6 family, and the whole codex-model family (`gpt-5.3-codex`,
  `gpt-5.2-codex`, `gpt-5.1-codex-max`, `gpt-5.1-codex`, `gpt-5-codex`,
  `gpt-5.1-codex-mini`, `codex-mini`), which the feed omits entirely and which
  are precisely the Codex-relevant ones. TSV display names map to ids
  mechanically via `downcase.tr(" ", "-")`, with a small hand-map for the few
  that differ (`Chat Latest` → `chatgpt-4o-latest`, `Codex Mini` →
  `codex-mini-latest`).

**Stated plainly:** the feed records no OpenAI price *changes* within its window,
so the baked history starts as a single tier per model. The structure is dated and
the accretion machinery is what earns its keep going forward. The earliest tier is
left open-ended backwards, so sessions predating 2026-04-16 still price. The
feed's window fully covers the local Codex data, which starts 2026-04-30.

Rates are the **standard** service tier — not batch, flex or priority — matching
`~/.codex/config.toml`'s `service_tier = "default"`.

### Layering

Highest precedence first:

1. **Config `model_rates`** — organisation-specific pricing. Config-only, like
   `remap`. Accepts a flat `{input:, output:, …}` or a tier array with
   `effective:` dates.
2. **Baked-in tables** — the offline-authoritative dated history.
3. **Runtime fetch** — gap-filler only, for models with *no* baked entry (a new
   model release we have not yet baked in).

Runtime fetch reads `https://www.aipricing.guru/api/pricing.json` (current rates,
one entry per model) rather than the history endpoint the rake task uses — a
gap-fill only needs today's price, and the smaller payload keeps the interactive
path cheap.

Runtime fetch deliberately never overrides baked data: if it did, the same
command would produce different numbers online and offline. It is cached to
`<store-dir>/pricing-cache.json` with the observation date recorded, so
subsequent offline runs still price the model. A fetched rate is stored as a
single open-ended tier — we only know it is current as of the fetch, so applying
it to older sessions is an estimate. That limitation gets a README note.

`--no-fetch-pricing` (config `fetch_pricing: false`) disables it. Nothing is
fetched when the cache already answers, so the common case makes no network call.

Threading: `CLI → Aggregator → Pricing.cost_for(model, usage, date, overrides:)`.
No global mutable state.

### `Pricing.provider`

New `Pricing.provider(model)` → `:anthropic` / `:openai` / `nil`, derived from
which table holds the entry.

`FAMILY_ORDER` gains `gpt` and `o` (the reasoning series: `o1`, `o3`, `o4-mini`),
placed after the Anthropic families so Claude models keep their current display
order. `sort_key`'s version parse becomes
`scan(/\d+/)` over the whole suffix so `gpt-5.5 < gpt-5.6`, with the normalized id
as a final tiebreaker for deterministic ordering of same-version variants
(`gpt-5.6-luna` / `-sol` / `-terra`).

`normalize_model` is unchanged: non-Claude ids pass through untouched, so Codex
models display as `gpt-5.6-sol`, `codex-auto-review` and so on.

### `codex-auto-review`

An internal Codex alias with no published rate — and **568 of 905 observed turns**,
so it dominates the local dataset. It ships unpriced; `model_rates` is how you
assign it a rate. The README gets a worked example. Totals understate until then,
and unpriced rows render as `—` / blank / `null` + `priced:false` exactly as
non-Claude models do today.

## 5. Price-refresh rake task

`rake pricing:openai` (and `pricing:anthropic`) fetches
`https://www.aipricing.guru/api/price-history.json` and rewrites the baked Ruby
table automatically.

Chosen deliberately over scraping OpenAI's own page: the official
`developers.openai.com/api/docs/pricing` embeds canonical ids and rates in its
Next.js flight payload, but it is an undocumented internal structure. The
third-party feed has a documented stable schema, no auth, and ETag support.

The tradeoff, stated once: a third-party-only source means the baked history
inherits someone else's scrape errors with no canonical cross-check, and
auto-rewrite puts a parser misfire straight into the file with git as the only
safety net. Mitigations, which keep the workflow to one command:

- **Strictly append-only.** The writer never mutates or deletes an existing tier.
  A changed rate appends a new tier with `effective:` set to the observation date.
- **Compare against the tier active on the observation date**, not the last tier
  in the array. Otherwise a known *future* tier (sonnet-5's 2026-09-01 increase)
  would look like a price change and get spuriously appended.
- **Preserve dimensions the feed lacks.** The feed carries no cache-write rates;
  those are never dropped from an existing entry.
- **Sanity gates.** Refuse to write on a suspiciously small model count, or any
  non-positive or wildly out-of-range rate.
- **`--dry-run`** prints the diff without writing.

The feed's Anthropic rates match clauditor's current table exactly, which makes
this a genuine cross-check on both providers rather than only a source for OpenAI.

## 6. Project normalization

`ProjectNormalizer.raw` gains three rules, **in this order** — the ordering is
load-bearing:

1. `~/.codex/worktrees/<hex>/<repo>[/...]` → loose name `<repo>`, reattached to the
   canonical checkout by the existing `build_remap`. Note the layout is *reversed*
   from the `tmp/worktrees/<repo>/<name>` pattern already handled: the hash comes
   before the repo name.
2. `<repo>/.codex/...` → `<repo>`, mirroring the existing `.claude` rule — guarded
   so that a top-level `~/.codex/...` path never collapses to the home directory.
   Rule 1 must therefore run first.
3. `~/Documents/Codex/<date>/<slug>` → `~/Documents/Codex`, so ad-hoc Codex Desktop
   sessions bucket together instead of each becoming its own single-row project.

## 7. CLI surface

| Flag | Config key | Behaviour |
| --- | --- | --- |
| `--codex` / `--no-codex` | `codex` | Default **on** when a codex root exists |
| `--codex-root DIR` | `codex_roots` | Repeatable. Error if combined with `--no-codex` |
| `--openai` | `openai` | Mirror of `--anthropic`: OpenAI models across columns |
| `--source claude\|codex` | `source` | Filter, validated against a `SOURCES` constant |
| `--no-fetch-pricing` | `fetch_pricing` | Disable runtime gap-fill fetching |
| — | `model_rates` | Config-only, like `remap` |

`--openai` is mutually exclusive with `--anthropic` and with `--rollup`, and
unsupported with `--format json` — the same pre-load `exit 1` as `--anthropic`.
`--summary` collapses `gpt-5.6-{sol,terra,luna}` into a single `gpt` column via the
existing family-collapse logic.

`--source` is applied alongside `--project` / `--model`, after `Store#save`, so the
persisted dataset stays complete.

**No new Source column** in any formatter. Model ids already disambiguate, and a
column would churn every view and every CSV header for no information gain.
`--source` is purely a filter — but it needs the persisted field so it also works
on rows seeded from the Store.

### A breakage this design exists to prevent

`Crosstab.pivot` currently defines "is this an Anthropic model?" as
`Pricing.known?(row.model)`. The moment OpenAI rates enter `RATES`, that predicate
starts admitting `gpt-*` columns into existing `--anthropic` reports. So `pivot`
gains a `source:` parameter and selects on
`row.source == source && !row.cost.nil?`. The nil-cost exclusion must be kept —
`Table` and `Csv` both call `sum(&:cost)` and would raise on an unpriced row.

## 8. Testing

Synthetic Codex fixtures covering:

- duplicate `token_count` events with identical payloads
- `info: null` heartbeats
- a session spanning two calendar days
- a resumed file whose first event carries forward prior totals
- a decreasing total (context reset)
- a missing `turn_context` (model falls back, then to `"unknown"`)
- a `~/.codex/worktrees/<hex>/<repo>` cwd

Unit tests for: the OpenAI rate table, `model_rates` overrides in both flat and
tiered form, override-beats-baked precedence, `effective:` tier resolution
(including the migrated Anthropic entries and the nil/`"unknown"` date case),
`provider`, `sort_key` ordering, the three normalizer rules and their ordering,
Store v3 round-trip with `source`, and the append-only rake writer against a
recorded feed payload (no live network in tests).

CLI tests for each new flag, each conflict, and the `--anthropic` / `--openai`
source separation.

Then `bundle exec rake test` and `bundle exec rake lint`.

## 9. Docs

`README.md`, `CLAUDE.md` and `CHANGELOG.md` updated: the new flags and config keys,
the `model_rates` worked example for `codex-auto-review`, the pricing layering and
its offline guarantee, and the runtime-fetch estimate caveat.
