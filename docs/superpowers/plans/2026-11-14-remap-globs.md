# remap_globs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a config-only `remap_globs:` map that folds every project path matching a glob pattern onto one canonical project.

**Architecture:** `Config` parses and validates `remap_globs:` exactly like `remap:` (Hash of non-empty String => non-empty String, both `File.expand_path`-ed). `Aggregator` stores it and, in `rows`, applies it as a third remap layer after the automatic worktree reattachment and the exact `remap` lookup, matching with `File.fnmatch`. `CLI` plumbs the option through with a `{}` default.

**Tech Stack:** Ruby 3.4, minitest, rubocop-rails-omakase.

**Spec:** `docs/superpowers/specs/2026-11-14-remap-globs-design.md`

## Global Constraints

- All Ruby files start with `# frozen_string_literal: true`.
- rubocop-rails-omakase, trailing commas required in multiline array/hash literals; run `bundle exec rake lint:rubocop` before done.
- Gem versions stay unpinned.
- `remap_globs` is config-only — no CLI flag, no OptionParser entry.
- fnmatch flags are exactly `File::FNM_PATHNAME | File::FNM_EXTGLOB`.
- Exact `remap:` entries win over any glob; among globs, first match in config (insertion) order wins.

## Review Focus

- A `remap_globs:` whose value is not a Hash, or an entry with an empty/non-String side → `ArgumentError` surfaced as `clauditor: …` (covered in Task 1).
- A project path matching no glob is left unchanged (covered in Task 2).
- A glob and an exact `remap:` entry both applicable to the same path → exact wins (covered in Task 2).
- Seeded Store cells are remapped by globs and re-persist idempotently (covered in Task 2, idempotence step).
- A pattern containing `~` expands but keeps its glob metacharacters (covered in Task 1).

---

### Task 1: Config parses and validates `remap_globs:`

**Files:**
- Modify: `lib/clauditor/config.rb` (add `when "remap_globs"` near line 56; add `self.remap_globs` method near the existing `self.remap` at line 84)
- Test: `test/clauditor/config_test.rb`

**Interfaces:**
- Produces: `Config.load` returns `options[:remap_globs]` as a `{ expanded-pattern => expanded-path }` Hash (empty `{}` when the key is absent — CLI supplies that default, so Config omits the key when not present, matching how `remap` behaves).

- [ ] **Step 1: Write failing tests** in `config_test.rb`:
  - `test_remap_globs_expands_both_sides`: config `remap_globs:` with `~/Unity/Games/3DTDF2P/.claude/worktrees/*: ~/Unity/Games/3DTDF2P` yields `{ File.expand_path("~/Unity/Games/3DTDF2P/.claude/worktrees/*") => File.expand_path("~/Unity/Games/3DTDF2P") }` — assert the key still ends in `/*` (metachar survived expand).
  - `test_remap_globs_non_mapping_raises`: `remap_globs: just-a-string` raises `ArgumentError`.
  - `test_remap_globs_empty_target_raises`: `remap_globs:\n  "/a/*": ""` raises `ArgumentError`.
  Model these on the existing `test_remap_*` tests in the same file.

- [ ] **Step 2: Run tests, verify they fail**

Run: `bundle exec ruby -Itest test/clauditor/config_test.rb`
Expected: FAIL (unknown option `remap_globs` / NoMethodError).

- [ ] **Step 3: Implement.** Add `when "remap_globs"` → `options[:remap_globs] = remap_globs(value, path)`. Add `self.remap_globs(value, path)` mirroring `self.remap` (same Hash/non-empty-String validation and messages, with `'remap_globs'` in the text) and the same `mapping[File.expand_path(from)] = File.expand_path(to)` body.

- [ ] **Step 4: Run tests, verify they pass**

Run: `bundle exec ruby -Itest test/clauditor/config_test.rb`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/clauditor/config.rb test/clauditor/config_test.rb
git commit -m "feat: parse remap_globs config key"
```

### Task 2: Aggregator applies glob remapping

**Files:**
- Modify: `lib/clauditor/aggregator.rb` (`initialize` at line 38; `rows` glob application after line 110)
- Test: `test/clauditor/aggregator_test.rb`

**Interfaces:**
- Consumes: `Config` `remap_globs` Hash shape from Task 1.
- Produces: `Aggregator.new(..., remap_globs: {})` keyword; `rows` folds any project matching a glob onto its target.

- [ ] **Step 1: Write failing tests** in `aggregator_test.rb`, modeled on `test_remap_folds_stray_project_onto_canonical` and `test_remap_applies_to_seeded_cells`:
  - `test_remap_glob_folds_matching_projects_onto_canonical`: two added records with projects `/private/tmp/wt/a` and `/private/tmp/wt/b`, `remap_globs: { "/private/tmp/wt/*" => "/Users/me/games/tdf" }` → `rows` yields one project `/Users/me/games/tdf` with summed usage.
  - `test_remap_glob_leaves_nonmatching_project_unchanged`: a project `/Users/me/other` with the same glob stays `/Users/me/other`.
  - `test_exact_remap_wins_over_glob`: project `/private/tmp/wt/a`, `remap: { "/private/tmp/wt/a" => "/exact" }`, `remap_globs: { "/private/tmp/wt/*" => "/glob" }` → project is `/exact`.
  - `test_first_glob_wins`: two patterns both matching, assert the first in insertion order is used.
  - `test_remap_glob_applies_to_seeded_cells_idempotently`: `seed` a cell under a worktree path, apply the glob, then re-run `rows` on the folded result (seed the canonical path) and assert the canonical target (which does not match the glob) is unchanged.

- [ ] **Step 2: Run tests, verify they fail**

Run: `bundle exec ruby -Itest test/clauditor/aggregator_test.rb`
Expected: FAIL (unknown keyword `remap_globs`).

- [ ] **Step 3: Implement.** Add `remap_globs: {}` to `initialize`, store `@remap_globs = remap_globs`. In `rows`, after `canonical = @remap.fetch(canonical, canonical)` (line 110), when `canonical` was not changed by an exact entry, scan `@remap_globs` and set `canonical` to the target of the first pattern for which `File.fnmatch(pattern, canonical, File::FNM_PATHNAME | File::FNM_EXTGLOB)` is true. Guard so an empty `@remap_globs` is a no-op.

- [ ] **Step 4: Run tests, verify they pass**

Run: `bundle exec ruby -Itest test/clauditor/aggregator_test.rb`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/clauditor/aggregator.rb test/clauditor/aggregator_test.rb
git commit -m "feat: apply remap_globs in aggregator"
```

### Task 3: CLI plumbs the option; docs

**Files:**
- Modify: `lib/clauditor/cli.rb` (default at line 197; `Aggregator.new` call at line 42)
- Modify: `CLAUDE.md` (`Config` bullet), `README.md`, `CHANGELOG.md`
- Test: `test/clauditor/cli_test.rb`

**Interfaces:**
- Consumes: Task 1 option, Task 2 keyword.

- [ ] **Step 1: Write failing test** in `cli_test.rb`, modeled on `test_config_remap_folds_stray_project_onto_canonical`: a config with `remap_globs:` folding a worktree path produces a report whose project column shows the canonical path.

- [ ] **Step 2: Run test, verify it fails**

Run: `bundle exec ruby -Itest test/clauditor/cli_test.rb -n test_config_remap_globs_folds_matching_projects`
Expected: FAIL.

- [ ] **Step 3: Implement.** Add `remap_globs: {}` to the defaults hash (after line 197) and `remap_globs: options[:remap_globs],` to the `Aggregator.new` call (after line 42).

- [ ] **Step 4: Run test, verify it passes**

Run: `bundle exec ruby -Itest test/clauditor/cli_test.rb -n test_config_remap_globs_folds_matching_projects`
Expected: PASS

- [ ] **Step 5: Document.** In `CLAUDE.md`, extend the `Config` bullet to describe `remap_globs` (config-only `{ glob-pattern => project-path }`, `fnmatch` with `FNM_PATHNAME|FNM_EXTGLOB`, applied after exact `remap`, exact wins, first glob wins). Add a short note to `README.md` next to `remap`. Add a `CHANGELOG.md` entry.

- [ ] **Step 6: Full suite + lint**

Run: `bundle exec rake test && bundle exec rake lint:rubocop`
Expected: PASS, no offenses.

- [ ] **Step 7: Commit**

```bash
git add lib/clauditor/cli.rb CLAUDE.md README.md CHANGELOG.md test/clauditor/cli_test.rb
git commit -m "feat: wire remap_globs through CLI and document it"
```
