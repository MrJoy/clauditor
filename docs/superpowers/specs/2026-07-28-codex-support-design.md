# Codex support — design

Date: 2026-07-28

Add OpenAI Codex CLI usage to clauditor's per-project, per-day, per-model report,
alongside the existing Claude Code data, with real dollar costs drawn from a dated
OpenAI price history — and restructure loading and pricing around registries so
further harnesses and further price sources are additive rather than invasive.

## 1. The Codex data format

Codex writes append-only JSONL "rollout" files:

- `~/.codex/sessions/YYYY/MM/DD/rollout-<iso>-<uuid>.jsonl`
- `~/.codex/archived_sessions/rollout-<iso>-<uuid>.jsonl` — a disjoint set of
  files (verified: zero filename overlap), not copies. Both directories count.

Relevant record types:

| `type` | `payload.type` | Carries |
| --- | --- | --- |
| `session_meta` | — | `id` (rollout id), `cwd`, `cli_version`, `originator`, `thread_source`, `git.repository_url`, `model` (usually `null`) |
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
without needing any dedupe bookkeeping.

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

## 2. Archive moves must not double-count

Codex relocates rollouts from `sessions/` to `archived_sessions/`. The analysis,
because the obvious risk and the real risk are different:

**Cross-run moves are already safe, for two independent reasons.** `mv` preserves
mtime, so a relocated file still satisfies the Store's invariant — mtime earlier
than `cutoff_time` implies it can only contain records from persisted days — and
is correctly skipped. And if the relocation *does* bump mtime, the file is
re-read, whereupon `skip_through` drops every record dated on or before
`complete_through`. Neither path can duplicate, and neither can lose data.

**The real hazard is intra-run.** If one rollout exists in both directories
simultaneously — a copy rather than a move, or a move observed mid-flight — the
two paths differ, so path-level `uniq` does not collapse them. Both files are
read, and because Codex dedup is *delta arithmetic over a file* rather than an id
lookup, each contributes its full usage. That is an exact doubling.

Claude is structurally immune: its dedup keys on `message.id`, which survives any
file shuffling, including a resumed session replaying old messages into a new
file. Codex needs an explicit equivalent, at two levels:

1. **File selection.** `Loaders::Codex#files` parses the rollout id from each
   basename (`rollout-<iso>-<uuid>.jsonl` → `<uuid>`, falling back to the whole
   basename if the pattern does not match) and keeps **one path per rollout id**.
   Where several exist, prefer the **largest file**, tie-broken by sorted path for
   determinism. Largest — not "prefer archived" — because the delta baseline
   depends on seeing the file's earlier events, so the most complete copy is the
   only safe one to read; a half-written archive copy would silently undercount.
2. **Stream-level guard.** While reading, record each `session_meta.payload.id`
   consumed and skip any file whose id has already been seen. This catches a copy
   whose filename was changed, which basename parsing alone would miss.

Both are covered by tests: the same rollout present in both directories, with the
archived copy truncated, must yield exactly the full-file total once.

## 3. Source registry and loader renames

To make additional harnesses additive, loading is restructured around a registry
and a single normalised record. The Claude-specific pieces are renamed into the
same scheme as the Codex ones.

### `Clauditor::Turn`

`lib/clauditor/turn.rb` — the one currency between loaders and the aggregator:

```ruby
Turn = Struct.new(:source, :cwd, :timestamp, :model, :usage, :dedupe_key,
                  keyword_init: true)
```

`dedupe_key` is the Claude `message.id`, and `nil` for Codex (whose dedup is
handled by the delta arithmetic and the rollout-id guard above).

### Loaders

| Was | Becomes |
| --- | --- |
| `Clauditor::SessionLoader` (`lib/clauditor/session_loader.rb`) | `Clauditor::Loaders::Claude` (`lib/clauditor/loaders/claude.rb`) |
| — | `Clauditor::Loaders::Codex` (`lib/clauditor/loaders/codex.rb`) |
| `SessionLoader::DEFAULT_ROOT` | `Loaders::Claude::DEFAULT_ROOTS` (now a list, for symmetry) |

Each loader exposes the same interface: `.new(roots:, since:)` and `#each_turn`,
yielding `Turn`s. The raw-JSONL reading, malformed-line skipping and `since:`
mtime filtering that `SessionLoader` does today move into a shared
`Loaders::Jsonl` mixin, since both harnesses write append-only JSONL and both
need identical treatment (a truncated final line is normal).

`Loaders::Claude` absorbs the record interpretation currently living in
`Aggregator#add`: the `type == "assistant"` check, the `<synthetic>` exclusion,
`Usage.from_message_usage`, and emitting `dedupe_key` from `message.id`.

`SessionLoader` is removed outright rather than aliased. It is internal to this
tool, has no external consumers, and a lingering alias would undercut the point of
the rename.

### `Clauditor::Sources`

`lib/clauditor/sources.rb` — the registry the CLI and Store iterate over instead
of naming harnesses inline:

```ruby
Sources::ALL  # => [Sources::Claude, Sources::Codex]
```

Each entry answers: `.name` (`"claude"` / `"codex"` — the value persisted in rows
and accepted by `--source`), `.default_roots`, `.available?` (do any default roots
exist), `.root_flag` (`"--claude-root"` / `"--codex-root"`), `.config_key`
(`claude_roots` / `codex_roots`), and `.loader(roots:, since:)`.

Adding a harness then means one new file under `loaders/` plus one registry entry.
`SOURCES` validation for `--source`, the per-source root options, and the Store's
root bookkeeping all derive from the registry rather than repeating a hardcoded
list.

## 4. `Aggregator` and the `source` dimension

With interpretation moved into the loaders, `Aggregator` narrows to what its name
says. `#add(record)` is replaced by `#add_turn(turn)`:

- Group key becomes `[source, project, day, model]`.
- `Row` gains a `source` member.
- `seed` gains a `source:` keyword.
- Dedup keys on `[source, dedupe_key]` and is skipped entirely when `dedupe_key`
  is nil. It stays global across files, exactly as today, because resumed Claude
  sessions replay earlier messages into new files.
- `covered?`, project remapping and cost assignment are unchanged.

One deliberate behaviour change: today `covered?` returns before a record's
`message.id` is marked seen; after the move, the dedupe mark happens first. This
is inert — a given `message.id` carries one timestamp, so it belongs to exactly
one day and can never be both covered and uncovered.

## 5. Store: schema and transparent migration

`Store::VERSION` → `3`. Changes:

- Rows carry `"source"`.
- The payload key `roots` becomes `claude_roots`, joined by `codex_roots`. Both
  are sorted and de-duplicated, both stored, both validated on load.
- The path hash covers both root lists.

### Migrating an existing v2 store

A version bump normally means discarding the cache and doing a full rescan. That
is avoidable here, and the migration is worth doing because it keeps warm runs
warm through the upgrade:

On load, when no v3 file exists at the new path, compute the **legacy v2 path**
(SHA256 over `claude_roots.join("\n")` — identical to today's computation, since
pre-Codex roots were Claude-only) and try to read it. If it validates as v2,
adopt its `complete_through` and its rows, assigning `source: "claude"` to every
row. That attribution is sound by construction: a v2 store predates Codex support
and can only contain Claude data.

The next `save` writes v3 at the new path. The legacy v2 file is left in place
rather than deleted — it is inert once v3 exists, costs nothing, and leaving it
means downgrading to a previous clauditor still finds its cache.

## 6. Pricing

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

- **`aipricing.guru`'s history endpoint** — 103 dated snapshots spanning
  2026-04-16 … 2026-07-28. Bare canonical ids (`gpt-5.6-sol`) matching what Codex
  logs. Collapsed into `effective:` tiers by walking snapshots oldest-first and
  emitting a tier only where rates change. Covers 24 OpenAI models.
- **The provided TSV snapshot** — supplies what the feed lacks: cache-write rates
  for the 5.6 family, and the whole codex-model family (`gpt-5.3-codex`,
  `gpt-5.2-codex`, `gpt-5.1-codex-max`, `gpt-5.1-codex`, `gpt-5-codex`,
  `gpt-5.1-codex-mini`, `codex-mini`), which the feed omits entirely and which are
  precisely the Codex-relevant ones. TSV display names map to ids mechanically via
  `downcase.tr(" ", "-")`, with a small hand-map for the few that differ
  (`Chat Latest` → `chatgpt-4o-latest`, `Codex Mini` → `codex-mini-latest`).

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

Runtime fetch reads the price sources' *current* endpoint rather than the history
endpoint the rake task uses — a gap-fill only needs today's price, and the smaller
payload keeps the interactive path cheap.

Runtime fetch deliberately never overrides baked data: if it did, the same command
would produce different numbers online and offline. It is cached to
`<store-dir>/pricing-cache.json` with the observation date and source name
recorded, so subsequent offline runs still price the model. A fetched rate is
stored as a single open-ended tier — we only know it is current as of the fetch,
so applying it to older sessions is an estimate. That limitation gets a README
note.

`--no-fetch-pricing` (config `fetch_pricing: false`) disables it. Nothing is
fetched when the cache already answers, so the common case makes no network call.

Threading: `CLI → Aggregator → Pricing.cost_for(model, usage, date, overrides:)`.
No global mutable state.

### `Pricing.provider`

New `Pricing.provider(model)` → `:anthropic` / `:openai` / `nil`, derived from
which table holds the entry.

`FAMILY_ORDER` gains `gpt` and `o` (the reasoning series: `o1`, `o3`, `o4-mini`),
placed after the Anthropic families so Claude models keep their current display
order. `sort_key`'s version parse becomes `scan(/\d+/)` over the whole suffix so
`gpt-5.5 < gpt-5.6`, with the normalized id as a final tiebreaker for
deterministic ordering of same-version variants (`gpt-5.6-luna` / `-sol` /
`-terra`).

`normalize_model` is unchanged: non-Claude ids pass through untouched, so Codex
models display as `gpt-5.6-sol`, `codex-auto-review` and so on.

### `codex-auto-review`

An internal Codex alias with no published rate — and **568 of 905 observed
turns**, so it dominates the local dataset. It ships unpriced; `model_rates` is
how you assign it a rate. The README gets a worked example. Totals understate until
then, and unpriced rows render as `—` / blank / `null` + `priced:false` exactly as
non-Claude models do today.

## 7. Price-source registry

Reading the brief "prepare for a world in which we're pulling from multiple data
sources, so we can fill the codex gap later" as being about **price** sources —
the gap being that the chosen feed omits every codex-family model, which a second
source could later supply. (If harnesses were meant instead, §3's registry covers
that; say so and I will adjust.)

`lib/clauditor/price_sources/` with a registry mirroring `Sources`:

```ruby
PriceSources::ALL  # => [PriceSources::AiPricingGuru]
```

Each source answers `.name`, `.providers` (which vendors it covers),
`.fetch_history` (→ dated snapshots) and `.fetch_current` (→ one rate per model),
both returning already-normalised rate hashes keyed by clauditor's model ids, so
per-source id quirks stay inside the source.

Consumers merge across sources **in registry order, first-wins per model**, so
precedence is explicit and a later addition can only fill gaps, never silently
restate a model an earlier source already covers. The eventual codex-rate source
is then one file plus one registry entry.

`PriceSources::AiPricingGuru` wraps `aipricing.guru`: documented schema, no auth,
ETag support, and it covers Anthropic as well as OpenAI. Its id normalisation
strips `claude-` and converts dots to dashes for Anthropic
(`claude-haiku-4.5` → `haiku-4-5`) while leaving OpenAI ids as-is, since Codex
logs dotted ids (`gpt-5.6-sol`) verbatim.

## 8. Price-refresh rake task

`rake pricing:refresh` (with `pricing:openai` / `pricing:anthropic` to scope it)
fetches history across the registry and rewrites the baked Ruby tables
automatically.

Chosen deliberately over scraping OpenAI's own page: the official
`developers.openai.com/api/docs/pricing` embeds canonical ids and rates in its
Next.js flight payload, but it is an undocumented internal structure. The
third-party feed has a documented stable schema.

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

## 9. Project normalization

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

## 10. CLI and config surface

| Flag | Config key | Behaviour |
| --- | --- | --- |
| `--claude-root DIR` | `claude_roots` | Repeatable. Replaces config roots wholesale, as `--root` does today |
| `--root DIR` | `roots` | Deprecated alias for the above; accepted silently |
| `--codex` / `--no-codex` | `codex` | Default **on** when a codex root exists |
| `--codex-root DIR` | `codex_roots` | Repeatable. Error if combined with `--no-codex` |
| `--openai` | `openai` | Mirror of `--anthropic`: OpenAI models across columns |
| `--source claude\|codex` | `source` | Filter; valid values come from the `Sources` registry |
| `--no-fetch-pricing` | `fetch_pricing` | Disable runtime gap-fill fetching |
| — | `model_rates` | Config-only, like `remap` |

### Key migration

`roots` → `claude_roots` migrates transparently, in both places it appears:

- **Config file.** `Config` accepts `roots` as a legacy alias for `claude_roots`,
  translating it to the same internal option symbol. Supplying both is an
  `ArgumentError`, consistent with how `Config` already rejects ill-typed input —
  silently picking one would hide a real contradiction in the user's file.
- **CLI.** `--root` remains a working alias for `--claude-root`. Both accumulate
  into the same list, so mixing them is harmless.
- **Store.** Covered by §5's v2 migration.

Nothing an existing user has configured stops working, and nothing needs a manual
edit.

### Other CLI notes

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

## 11. Testing

Codex loader fixtures covering:

- duplicate `token_count` events with identical payloads
- `info: null` heartbeats
- a session spanning two calendar days
- a resumed file whose first event carries forward prior totals
- a decreasing total (context reset)
- a missing `turn_context` (model falls back, then to `"unknown"`)
- a `~/.codex/worktrees/<hex>/<repo>` cwd
- **the same rollout in both `sessions/` and `archived_sessions/`**, archived copy
  truncated — must total the full file exactly once
- the same rollout under a renamed file, caught by the `session_meta.id` guard

Unit tests for: the OpenAI rate table; `model_rates` overrides flat and tiered;
override-beats-baked precedence; `effective:` tier resolution including the
migrated Anthropic entries and the nil/`"unknown"` date case; `provider`;
`sort_key` ordering; the three normalizer rules and their ordering; `Sources` and
`PriceSources` registry contracts (every entry answers the full interface);
first-wins merge order across price sources; Store v3 round-trip with `source`;
**Store v2 → v3 migration** (legacy path found, rows adopted as `source: "claude"`,
`complete_through` preserved, legacy file left intact); config `roots` alias
including the both-keys error; and the append-only rake writer against a recorded
feed payload — no live network in any test.

CLI tests for each new flag, each conflict, `--root`/`--claude-root` equivalence,
and the `--anthropic` / `--openai` source separation.

Then `bundle exec rake test` and `bundle exec rake lint`.

## 12. Docs

`README.md`, `CLAUDE.md` and `CHANGELOG.md` updated: the new flags and config keys,
the `roots` → `claude_roots` migration, the `model_rates` worked example for
`codex-auto-review`, the pricing layering and its offline guarantee, the
runtime-fetch estimate caveat, and how to add a harness or a price source given the
registries.
