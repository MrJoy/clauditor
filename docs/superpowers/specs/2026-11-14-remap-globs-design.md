# remap_globs: glob-pattern project remapping

## Intent / why

The config `remap:` map folds stray project paths (long-gone worktrees the
repo-root walk can no longer resolve) onto a canonical checkout, one exact
`path => path` pair at a time. For projects with many worktrees the list has
grown unmanageably long. A single glob should fold a whole worktree tree onto
one canonical path.

## Goals

- A config-only `remap_globs:` map of `{ glob-pattern => canonical-path }` that
  folds every matching project path onto the canonical target.
- `~` expands on both sides; glob metacharacters on the pattern side survive.
- Coexists with `remap:`; exact `remap:` entries win over any glob.

## Non-goals

- No CLI flag (both `remap` and `remap_globs` stay config-only).
- No change to `ProjectNormalizer.build_remap` (the automatic loose-worktree
  reattachment). Globs are a third, user-driven layer on top of it.
- No glob support on the target side — the target is a single literal path.

## Anti-goals

- Changing how `remap:` already behaves, or its performance for the exact case.

## Approaches considered

- **A. Same `remap:` map, auto-detect glob metacharacters.** One config key;
  an entry with `*`/`?`/`[` in its key matches as a glob. Rejected: mixing
  literal and glob semantics in one map is easy to misread.
- **B. Separate `remap_globs:` key.** (chosen) Literal and glob rules stay
  visibly distinct. Cost is a second config key that mirrors `remap:`.

## How it works

**Config (`Config.remap_globs`, mirrors `Config.remap`):**
- `remap_globs:` must be a Hash; each entry maps a non-empty String pattern to
  a non-empty String path, else `ArgumentError` (`clauditor: …`), same shape as
  the existing `remap` validation.
- Both sides run through `File.expand_path` so `~` resolves; `expand_path`
  leaves `*`/`**`/`?`/`[` untouched, so the pattern survives.
- Config-only key, translated to the `:remap_globs` option symbol.

**Aggregator:**
- `initialize` gains `remap_globs: {}`, stored as `@remap_globs`.
- In `rows`, after the existing exact lookup
  (`canonical = @remap.fetch(canonical, canonical)`), if `canonical` is still
  unmapped, test it against each glob pattern with
  `File.fnmatch(pattern, canonical, File::FNM_PATHNAME | File::FNM_EXTGLOB)`.
  First pattern that matches (config/insertion order) sets the canonical
  target; exact `remap:` entries therefore always win over globs.
- `FNM_PATHNAME` keeps `*` within a path segment and lets `**/` span
  directories, so `~/x/.claude/worktrees/*` matches one level and
  `**/worktrees/*` matches any depth — the way worktree trees are expected to
  glob.

**CLI:** passes `remap_globs: options[:remap_globs]`, default `{}` (line 197).

## Idempotence

Like `remap`, globs reach seeded Store cells and must re-persist cleanly. A
glob folds a worktree path onto a canonical target; provided the canonical
target does not itself match the glob (the normal case — canonical checkouts
live outside the globbed worktree dirs), a second run re-folds nothing new.
This is the same contract the exact `remap` already relies on, noted so the
builder preserves it in tests.

## Left to the builder

- Exact method names/placement following the existing `remap` code.
- Test coverage: config parse + validation errors, aggregator glob fold,
  exact-wins-over-glob precedence, first-glob-wins ordering, CLI config
  integration. Docs: CLAUDE.md `Config` bullet, README, CHANGELOG.
